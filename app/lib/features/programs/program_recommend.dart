// 추가 시트의 "추천" 계산. 앱 로컬 정보(최근 4주 운동 횟수 + 3대 1RM 기록 유무)만 쓴다.
// 계산은 순수 함수 recommendTemplates 로 분리해 단위 테스트한다.
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/program_dto.dart';
import '../../core/clock.dart';
import '../../data/providers.dart';

/// 추천 근거 종류. 문구는 화면이 고른다.
enum RecReasonKind {
  /// 최근 4주 기록이 거의 없음.
  fresh,

  /// 꾸준히 하지만 3대 기록이 없음 → 입문.
  steadyBeginner,

  /// 주 3회 안팎 + 3대 기록 있음.
  steady,

  /// 주 4회 이상 + 3대 기록 있음 → 중급.
  strong,
}

class RecReason {
  const RecReason(this.kind, this.perWeek);
  final RecReasonKind kind;

  /// 주간 평균(반올림).
  final int perWeek;
}

class Recommendation {
  const Recommendation(this.programs, this.reason);

  /// 추천 템플릿 최대 2개(묶음은 하나만, 가장 맞는 변형).
  final List<ProgramSummary> programs;
  final RecReason reason;
}

/// 입력: 템플릿 목록, 최근 4주 주간 평균 운동 횟수, 3대 1RM 기록 유무, 진행 중 프로그램 id.
/// 규칙:
/// - 주 1회 미만 → 입문 + 주 3일.
/// - 주 4회 이상 + 1RM 있음 → 중급 + 주 4~5일(4 우선).
/// - 그 밖: 횟수(3~5로 맞춤)에 맞는 일수, 1RM 있으면 중급 없으면 입문.
/// 이미 진행 중인 템플릿은 제외. 후보가 없으면 null.
Recommendation? recommendTemplates({
  required List<ProgramSummary> templates,
  required double weeklyAvg,
  required bool hasOneRm,
  Set<String> runningIds = const {},
  int max = 2,
}) {
  final kind = weeklyAvg < 1
      ? RecReasonKind.fresh
      : !hasOneRm
      ? RecReasonKind.steadyBeginner
      : weeklyAvg.round() >= 4
      ? RecReasonKind.strong
      : RecReasonKind.steady;
  final perWeek = weeklyAvg.round();
  final wantLevel =
      (kind == RecReasonKind.strong || kind == RecReasonKind.steady)
      ? 'INTERMEDIATE'
      : 'BEGINNER';
  final wantDays = kind == RecReasonKind.fresh
      ? 3
      : math.min(5, math.max(3, perWeek));

  int levelDist(String? lv) {
    if (lv == wantLevel) return 0;
    if (lv == 'BEGINNER' || lv == 'INTERMEDIATE') return 1;
    return 2; // 상급·모르는 값은 추천하지 않을 만큼 뒤로.
  }

  // 주 4~5일 중급은 4일을 5일보다 먼저.
  int dayDist(int d) {
    if (kind == RecReasonKind.strong && (d == 4 || d == 5)) {
      return d == 4 ? 0 : 1;
    }
    return (d - wantDays).abs();
  }

  final cands = [
    for (final p in templates)
      if (p.builtIn &&
          !runningIds.contains(p.id) &&
          (p.level == 'BEGINNER' || p.level == 'INTERMEDIATE'))
        p,
  ];
  final order = {for (final (i, p) in cands.indexed) p.id: i};
  cands.sort((a, b) {
    final c = levelDist(a.level).compareTo(levelDist(b.level));
    if (c != 0) return c;
    final d = dayDist(a.dayCount).compareTo(dayDist(b.dayCount));
    return d != 0 ? d : order[a.id]!.compareTo(order[b.id]!);
  });
  final picked = <ProgramSummary>[];
  final families = <String>{};
  for (final p in cands) {
    if (p.family != null && !families.add(p.family!)) continue;
    picked.add(p);
    if (picked.length == max) break;
  }
  if (picked.isEmpty) return null;
  return Recommendation(picked, RecReason(kind, perWeek));
}

/// 추천 재료. 읽기에 실패하면 에러로 끝나고, 화면은 추천만 숨긴다.
class RecommendInputs {
  const RecommendInputs(this.weeklyAvg, this.hasOneRm);
  final double weeklyAvg;
  final bool hasOneRm;
}

/// 서버 기본 종목 id: 스쿼트·벤치프레스·데드리프트·오버헤드 프레스.
const _bigLiftIds = [
  '019b76da-4000-7000-8000-000000000001',
  '019b76da-4000-7000-8000-000000000003',
  '019b76da-4000-7000-8000-000000000006',
  '019b76da-4000-7000-8000-000000000009',
];

final recommendInputsProvider = FutureProvider.autoDispose<RecommendInputs>((
  ref,
) async {
  final now = ref.read(clockProvider)();
  final sessions = await ref
      .read(sessionRepositoryProvider)
      .watchSessionsBetween(
        now.subtract(const Duration(days: 28)),
        now.add(const Duration(days: 1)),
      )
      .first;
  final records = ref.read(recordsRepositoryProvider);
  var has = false;
  for (final id in _bigLiftIds) {
    final r = await records.records(id);
    if (r.latestMeasured != null || r.bestE1rm != null) {
      has = true;
      break;
    }
  }
  return RecommendInputs(sessions.length / 4, has);
});
