import '../l10n/gen/app_localizations.dart';

/// 3대 운동 한 종목: 서버 시드 종목 id와 짧은 이름 키(테스트 key 접미사).
class Big3Lift {
  const Big3Lift(this.id, this.key);
  final String id;
  final String key; // squat / bench / dead

  String shortName(AppLocalizations l) => switch (key) {
    'squat' => l.big3ShortSquat,
    'bench' => l.big3ShortBench,
    _ => l.big3ShortDead,
  };

  /// 종목 목록을 아직 못 불러왔을 때 쓰는 전체 이름.
  String fullName(AppLocalizations l) => switch (key) {
    'squat' => l.big3FullSquat,
    'bench' => l.big3FullBench,
    _ => l.big3FullDead,
  };
}

/// 서버 기본 종목: 스쿼트·벤치프레스·데드리프트(이 순서로 보여 준다).
const big3Lifts = [
  Big3Lift('019b76da-4000-7000-8000-000000000001', 'squat'),
  Big3Lift('019b76da-4000-7000-8000-000000000003', 'bench'),
  Big3Lift('019b76da-4000-7000-8000-000000000006', 'dead'),
];

final big3Ids = [for (final b in big3Lifts) b.id];

/// 오버헤드 프레스(3대에는 넣지 않고 프로그램 추천에서만 쓴다).
const ohpExerciseId = '019b76da-4000-7000-8000-000000000009';
