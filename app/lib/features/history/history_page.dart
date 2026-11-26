// B3 소유. STA-1 히스토리: 끝난 세션을 월별로 묶어 보여주고, 아래로 스크롤하면 더 불러온다.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/dto.dart';
import '../../core/routes.dart';
import '../../core/settings/settings_controller.dart';
import '../../data/providers.dart';
import '../../l10n/gen/app_localizations.dart';
import '../session/session_controller.dart' show sessionByIdProvider;
import '../session/session_format.dart';
import '../source_badge/source_badge.dart';

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
  HistoryMonthHeader(this.year, this.month);
  final int year;
  final int month;
}

class HistorySessionItem extends HistoryItem {
  HistorySessionItem(this.summary);
  final SessionSummary summary;
}

/// 진행 중 세션은 빼고, 세션 시간대 기준 시작 날짜의 월로 묶는다. 입력은 최신순이라고 본다.
List<HistoryItem> groupByMonth(List<SessionSummary> sessions) {
  final out = <HistoryItem>[];
  int? lastKey;
  for (final s in sessions) {
    if (s.endedAt == null) continue;
    final local = sessionLocalTime(s.startedAt, s.tz);
    final key = local.year * 100 + local.month;
    if (key != lastKey) {
      out.add(HistoryMonthHeader(local.year, local.month));
      lastKey = key;
    }
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
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
              child: Text(
                l.historyMonth(h.year, h.month),
                style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary),
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
      appBar: AppBar(title: Text(l.historyTitle)),
      body: Column(
        children: [
          ListTile(
            key: const Key('history-records'),
            leading: const Icon(Icons.emoji_events_outlined),
            title: Text(l.historyExerciseRecords),
            trailing: const Icon(Icons.chevron_right),
            onTap: _openRecords,
          ),
          const Divider(height: 1),
          Expanded(child: body),
        ],
      ),
    );
  }
}

class _SessionTile extends ConsumerWidget {
  const _SessionTile({required this.summary, required this.unit});
  final SessionSummary summary;
  final WeightUnit unit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final s = summary;
    final local = sessionLocalTime(s.startedAt, s.tz);
    // 요약에는 프로그램 정보가 없어 세션 상세를 읽어 회차를 확인한다.
    final full = ref.watch(sessionByIdProvider(s.id)).value;
    final badge = full == null || !full.isProgram
        ? null
        : (full.planDayKey == null
              ? l.historyProgram
              : (full.planSeq == null ? full.planDayKey! : l.historyPlanBadge(full.planDayKey!, full.planSeq!)));
    void edit() => context.push(Routes.sessionEdit(s.id));
    return ListTile(
      key: Key('history-${s.id}'),
      title: Row(
        children: [
          Text('${formatDate(local)} ${formatClock(local)}'),
          if (full != null && full.isFromAi) ...[
            const SizedBox(width: 8),
            SourceBadge(key: Key('source-${s.id}'), source: full.source, importBatchId: full.importBatchId),
          ],
          if (badge != null) ...[
            const SizedBox(width: 8),
            Flexible(
              child: Chip(
                key: Key('badge-${s.id}'),
                label: Text(badge, overflow: TextOverflow.ellipsis),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
              ),
            ),
          ],
        ],
      ),
      subtitle: Text(l.historySummary(s.exerciseCount, s.setCount, formatVolume(s.totalVolumeKg, unit))),
      onTap: () => context.push(Routes.sessionDetail(s.id)),
      onLongPress: edit,
      trailing: PopupMenuButton<String>(
        key: Key('menu-${s.id}'),
        tooltip: l.historyMenu,
        onSelected: (_) => edit(),
        itemBuilder: (_) => [
          PopupMenuItem(value: 'edit', key: Key('menu-edit-${s.id}'), child: Text(l.historyEdit)),
        ],
      ),
    );
  }
}
