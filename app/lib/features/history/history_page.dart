// B3 소유. STA-1 히스토리: 끝난 세션을 월별로 묶어 보여주고, 아래로 스크롤하면 더 불러온다.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/dto.dart';
import '../../core/routes.dart';
import '../../core/settings/settings_controller.dart';
import '../../core/theme.dart';
import '../../core/units.dart';
import '../../data/providers.dart';
import '../../l10n/gen/app_localizations.dart';
import '../session/session_controller.dart' show exerciseMapProvider, sessionByIdProvider;
import '../session/session_format.dart';
import '../exercise_picker/exercise_labels.dart';
import '../source_badge/source_badge.dart';
import '../sync_status/sync_status_indicator.dart';

const historyPageSize = 20;

/// 지금 불러올 최대 개수. 끝까지 스크롤하면 [historyPageSize]씩 늘린다.
class HistoryLimit extends Notifier<int> {
  @override
  int build() => historyPageSize;
  void more() => state += historyPageSize;
}

final historyLimitProvider = NotifierProvider.autoDispose<HistoryLimit, int>(HistoryLimit.new);

final historySessionsProvider = StreamProvider.autoDispose<List<SessionSummary>>((ref) {
  final limit = ref.watch(historyLimitProvider);
  return ref.watch(sessionRepositoryProvider).watchRecentSessions(limit: limit);
});

/// 월 머리글과 세션을 한 줄로 늘어놓은 목록 항목.
sealed class HistoryItem {}

class HistoryMonthHeader extends HistoryItem {
  HistoryMonthHeader(this.year, this.month, {this.count = 0, this.volumeKg = 0});
  final int year;
  final int month;

  /// 불러온 범위 안에서 이 달의 끝난 세션 수와 볼륨 합.
  int count;
  double volumeKg;
}

class HistorySessionItem extends HistoryItem {
  HistorySessionItem(this.summary);
  final SessionSummary summary;
}

/// 진행 중 세션은 빼고, 세션 시간대 기준 시작 날짜의 월로 묶는다. 입력은 최신순이라고 본다.
List<HistoryItem> groupByMonth(List<SessionSummary> sessions) {
  final out = <HistoryItem>[];
  int? lastKey;
  HistoryMonthHeader? head;
  for (final s in sessions) {
    if (s.endedAt == null) continue;
    final local = sessionLocalTime(s.startedAt, s.tz);
    final key = local.year * 100 + local.month;
    if (key != lastKey) {
      head = HistoryMonthHeader(local.year, local.month);
      out.add(head);
      lastKey = key;
    }
    head!
      ..count += 1
      ..volumeKg += s.totalVolumeKg;
    out.add(HistorySessionItem(s));
  }
  return out;
}

class HistoryPage extends ConsumerStatefulWidget {
  const HistoryPage({super.key});

  @override
  ConsumerState<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends ConsumerState<HistoryPage> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybeLoadMore);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _maybeLoadMore() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    if (pos.pixels >= pos.maxScrollExtent - 300) _loadMore();
  }

  /// 지난번 요청한 개수만큼 다 채워 받았을 때만 더 요청한다(더 없으면 멈춤).
  void _loadMore() {
    final list = ref.read(historySessionsProvider).value;
    final limit = ref.read(historyLimitProvider);
    if (list != null && list.length >= limit) ref.read(historyLimitProvider.notifier).more();
  }

  Future<void> _openRecords() async {
    final id = await context.push<String>(Routes.pickExercise);
    if (id != null && mounted) context.push(Routes.exerciseRecords(id));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final async = ref.watch(historySessionsProvider);
    final unit = ref.watch(settingsProvider).weightUnit;
    final list = async.value;

    Widget body;
    if (list == null) {
      body = async.hasError
          ? Center(child: Text(l.historyLoadFailed))
          : const Center(child: CircularProgressIndicator());
    } else {
      final items = groupByMonth(list);
      if (items.isEmpty && list.length < ref.watch(historyLimitProvider)) {
        body = Center(child: Text(l.historyEmpty, key: const Key('history-empty')));
      } else {
        body = ListView.builder(
          key: const Key('history-list'),
          controller: _scroll,
          itemCount: items.length,
          itemBuilder: (context, i) => switch (items[i]) {
            HistoryMonthHeader h => Padding(
              key: Key('month-${h.year}-${h.month}'),
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    l.historyMonth(h.year, h.month),
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      l.histMonthStats(h.count, _volumeText(h.volumeKg, unit)),
                      key: Key('month-stats-${h.year}-${h.month}'),
                      style: TextStyle(fontSize: 13, color: AppColors.of(context).fg2),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            HistorySessionItem s => _SessionTile(summary: s.summary, unit: unit),
          },
        );
        // 첫 화면이 짧아 스크롤이 안 생기는 경우에도 더 불러온다.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _scroll.hasClients && _scroll.position.maxScrollExtent <= 0) _loadMore();
        });
      }
    }

    return Scaffold(
      appBar: AppBar(title: Text(l.historyTitle), actions: const [SyncStatusIndicator(), SizedBox(width: 8)]),
      body: Column(
        children: [
          ListTile(
            key: const Key('history-records'),
            minTileHeight: 56,
            leading: Icon(Icons.emoji_events_outlined, color: AppColors.of(context).pr),
            title: Text(l.historyExerciseRecords),
            trailing: const Icon(Icons.chevron_right),
            onTap: _openRecords,
          ),
          Divider(height: 1, color: AppColors.of(context).line),
          Expanded(child: body),
        ],
      ),
    );
  }
}

/// "71,300kg" 꼴(천 단위 쉼표, 단위 붙여 쓰기).
String _volumeText(double kg, WeightUnit unit) =>
    '${NumberFormat('#,###').format(Units.toDisplay(kg, unit).round())}${unit == WeightUnit.KG ? 'kg' : 'lb'}';

/// 활성 프로그램 인스턴스 id → 이름. 계획 캐시가 없거나 실패해도 빈 맵.
final _instanceNamesProvider = StreamProvider.autoDispose<Map<String, String>>((ref) {
  try {
    return ref
        .watch(planCacheProvider)
        .watchActive()
        .map((l) => {for (final p in l) p.instance.id: p.instance.name})
        .handleError((_) {});
  } catch (_) {
    return const Stream.empty();
  }
});

class _SessionTile extends ConsumerWidget {
  const _SessionTile({required this.summary, required this.unit});
  final SessionSummary summary;
  final WeightUnit unit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final c = AppColors.of(context);
    final s = summary;
    final local = sessionLocalTime(s.startedAt, s.tz);
    // 요약에는 프로그램 정보가 없어 세션 상세를 읽어 회차·종목을 확인한다.
    final full = ref.watch(sessionByIdProvider(s.id)).value;
    final exMap = ref.watch(exerciseMapProvider).value ?? const <String, Exercise>{};
    final names = ref.watch(_instanceNamesProvider).value ?? const <String, String>{};

    String? badge;
    if (full != null && full.isProgram) {
      final name = names[full.programInstanceId];
      badge = full.planDayKey == null
          ? (name ?? l.historyProgram)
          : (full.planSeq == null
                ? (name == null ? full.planDayKey! : '$name · ${full.planDayKey}')
                : (name == null
                      ? l.historyPlanBadge(full.planDayKey!, full.planSeq!)
                      : l.histPlanLine(name, full.planDayKey!, full.planSeq!)));
    }
    final exNames = <String>[
      if (full != null)
        for (final se in full.exercises)
          if (exMap[se.exerciseId] != null) exerciseDisplayName(context, exMap[se.exerciseId]!),
    ];
    final exLine = exNames.isEmpty
        ? l.historySummary(s.exerciseCount, s.setCount, formatVolume(s.totalVolumeKg, unit))
        : exNames.length <= 2
              ? exNames.join(' · ')
              : '${exNames.take(2).join(' · ')} ${l.histMore(exNames.length - 2)}';
    final days = l.histWeekdays.split(',');
    final weekday = days[(local.weekday - 1) % days.length];
    final vol = NumberFormat('#,###').format(Units.toDisplay(s.totalVolumeKg, unit).round());
    final unitText = unit == WeightUnit.KG ? 'kg' : 'lb';
    void edit() => context.push(Routes.sessionEdit(s.id));

    return InkWell(
      key: Key('history-${s.id}'),
      onTap: () => context.push(Routes.sessionDetail(s.id)),
      onLongPress: edit,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 72),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 4, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 44),
                child: Column(
                  children: [
                    Text('${local.day}', key: Key('history-day-${s.id}'), style: AppNum.style(context, 28, weight: FontWeight.w700)),
                    Text(weekday, style: TextStyle(fontSize: 12, color: c.fg2)),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (badge != null)
                      Text(
                        badge,
                        key: Key('badge-${s.id}'),
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                        overflow: TextOverflow.ellipsis,
                      )
                    else
                      Text(l.histFreeWorkout, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(exLine, style: TextStyle(fontSize: 13, color: c.fg2), overflow: TextOverflow.ellipsis),
                    if (full != null && full.isFromAi)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: SourceBadge(key: Key('source-${s.id}'), source: full.source, importBatchId: full.importBatchId),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // 큰 글씨에서도 한 줄이 넘치지 않게 볼륨 칸은 줄어든다.
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(vol, key: Key('history-volume-${s.id}'), style: AppNum.medium(context)),
                      Text(unitText, style: TextStyle(fontSize: 12, color: c.fg2)),
                    ],
                  ),
                ),
              ),
              PopupMenuButton<String>(
                key: Key('menu-${s.id}'),
                tooltip: l.historyMenu,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 40, minHeight: 48),
                onSelected: (_) => edit(),
                itemBuilder: (_) => [PopupMenuItem(value: 'edit', key: Key('menu-edit-${s.id}'), child: Text(l.historyEdit))],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
