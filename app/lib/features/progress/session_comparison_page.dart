// STA-4 그래프 비교(목업 6번). 위 세그먼트로 '회차 비교 / 추이'를 오가고, 종목 칩으로 종목을 고른다.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/api_client.dart' show ApiException;
import '../../core/api/dto.dart' show WeightUnit;
import '../../core/api/stats_dto.dart';
import '../../core/routes.dart';
import '../../core/settings/settings_controller.dart';
import '../../core/theme.dart';
import '../../core/units.dart';
import '../../data/providers.dart';
import '../../l10n/gen/app_localizations.dart';
import '../exercise_picker/exercise_labels.dart';
import '../session/session_controller.dart' show exerciseMapProvider;
import '../sync_status/sync_status_indicator.dart';
import 'compare_charts.dart';
import 'exercise_progress_page.dart' show exerciseProgressProvider;
import 'progress_logic.dart';

final sessionComparisonProvider = FutureProvider.autoDispose.family<SessionComparison, String>((ref, id) async {
  // 방금 끝낸 세션은 아직 서버에 없을 수 있다. 먼저 동기화를 시도한다(실패해도 진행).
  try {
    await ref.read(syncServiceProvider).syncNow().timeout(const Duration(seconds: 8));
  } catch (_) {}
  return ref.watch(statsRepositoryProvider).comparison(id);
}, retry: (_, _) => null);

enum _CmpView { compare, trend }

class SessionComparisonPage extends ConsumerStatefulWidget {
  const SessionComparisonPage({super.key, required this.sessionId});
  final String sessionId;

  @override
  ConsumerState<SessionComparisonPage> createState() => _SessionComparisonPageState();
}

class _SessionComparisonPageState extends ConsumerState<SessionComparisonPage> {
  _CmpView _view = _CmpView.compare;
  String? _exerciseId;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final async = ref.watch(sessionComparisonProvider(widget.sessionId));
    final exMap = ref.watch(exerciseMapProvider).value;

    Widget body;
    if (async.hasError) {
      final err = async.error;
      final offline = err is ApiException && err.isNetwork;
      final notSynced = err is ApiException && err.statusCode == 404;
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                offline
                    ? l.progressOffline
                    : notSynced
                    ? l.progressCompareNotSynced
                    : l.progressLoadFailed,
                key: Key(offline ? 'compare-offline' : (notSynced ? 'compare-not-synced' : 'compare-error')),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                key: const Key('compare-retry'),
                onPressed: () => ref.invalidate(sessionComparisonProvider(widget.sessionId)),
                child: Text(l.commonRetry),
              ),
            ],
          ),
        ),
      );
    } else if (async.value == null) {
      body = const Center(child: CircularProgressIndicator());
    } else if (async.value!.exercises.isEmpty) {
      body = Center(child: Text(l.progressCompareEmpty, key: const Key('compare-empty')));
    } else {
      final data = async.value!;
      final sel = data.exercises.firstWhere((e) => e.exerciseId == _exerciseId, orElse: () => data.exercises.first);
      String nameOf(String id) {
        final ex = exMap?[id];
        return ex == null ? id : exerciseDisplayName(context, ex);
      }

      body = ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<_CmpView>(
              key: const Key('compare-view'),
              showSelectedIcon: true,
              style: const ButtonStyle(minimumSize: WidgetStatePropertyAll(Size(48, 48))),
              segments: [
                ButtonSegment(value: _CmpView.compare, label: Text(l.cmpTabCompare, maxLines: 1)),
                ButtonSegment(value: _CmpView.trend, label: Text(l.cmpTabTrend, maxLines: 1)),
              ],
              selected: {_view},
              onSelectionChanged: (s) => setState(() => _view = s.first),
            ),
          ),
          const SizedBox(height: 12),
          SingleChildScrollView(
            key: const Key('compare-chips'),
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final e in data.exercises)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      key: Key('compare-chip-${e.exerciseId}'),
                      label: Text(nameOf(e.exerciseId)),
                      selected: e.exerciseId == sel.exerciseId,
                      materialTapTargetSize: MaterialTapTargetSize.padded,
                      onSelected: (_) => setState(() => _exerciseId = e.exerciseId),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (_view == _CmpView.compare)
            _CompareView(key: Key('compare-card-${sel.exerciseId}'), c: sel)
          else
            _TrendView(key: Key('trend-${sel.exerciseId}'), exerciseId: sel.exerciseId),
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(l.cmpTitle), actions: const [SyncStatusIndicator(), SizedBox(width: 8)]),
      body: body,
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.items});
  final List<(LegendKind, String)> items;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Wrap(
      spacing: 16,
      runSpacing: 6,
      children: [
        for (final (kind, label) in items)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              LegendSwatch(kind),
              const SizedBox(width: 6),
              Text(label, style: TextStyle(fontSize: 12, color: AppColors.of(context).fg2)),
            ],
          ),
      ],
    ),
  );
}

/// 회차 비교: 세트별 횟수 막대 + 범례 + 표.
class _CompareView extends ConsumerWidget {
  const _CompareView({super.key, required this.c});
  final ExerciseComparison c;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final colors = AppColors.of(context);
    final unit = ref.watch(settingsProvider).weightUnit;
    final rows = setComparisons(c);
    final badges = prBadges(c);
    final prev = c.previous;
    String setText(SnapSet? s) => s == null ? '-' : '${Units.format(s.weightKg, unit, withUnit: false)}\u00d7${s.reps}';
    final lastDate = prev == null ? null : '${prev.startedAt.toLocal().month}/${prev.startedAt.toLocal().day}';

    TextStyle cell({Color? color}) => AppNum.table(context, color: color);
    Widget pad(Widget w, {Alignment a = Alignment.centerLeft}) =>
        Container(height: 40, alignment: a, child: w);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (prev == null) Chip(key: Key('first-${c.exerciseId}'), label: Text(l.progressFirstRecord)),
            if (badges.weight)
              Chip(
                key: Key('pr-weight-${c.exerciseId}'),
                avatar: Icon(Icons.star_rounded, size: 18, color: colors.pr),
                label: Text(l.progressWeightPrBadge),
                backgroundColor: colors.prSoft,
              ),
            if (badges.e1rm)
              Chip(
                key: Key('pr-e1rm-${c.exerciseId}'),
                avatar: Icon(Icons.star_rounded, size: 18, color: colors.pr),
                label: Text(l.progressE1rmPrBadge),
                backgroundColor: colors.prSoft,
              ),
          ],
        ),
        if (rows.isEmpty)
          Padding(padding: const EdgeInsets.all(16), child: Text(l.progressCompareEmpty))
        else ...[
          RepsBarChart(
            key: Key('compare-chart-${c.exerciseId}'),
            today: [for (final r in rows) r.today?.reps],
            last: [for (final r in rows) r.previous?.reps],
            prReps: c.bestWeight?.reps,
            setLabel: (n) => l.cmpSetShort(n),
            prLabel: l.cmpPrReps(c.bestWeight?.reps ?? 0),
            axisLabel: l.cmpAxisReps,
            semantics: l.cmpChartSemantics,
          ),
          _Legend(
            items: [
              (LegendKind.today, l.progressLegendToday),
              (LegendKind.last, lastDate == null ? l.cmpLegendLast : l.cmpLegendLastDate(lastDate)),
              if (c.bestWeight != null) (LegendKind.pr, l.cmpLegendPrReps),
            ],
          ),
          const SizedBox(height: 4),
          Table(
            key: Key('compare-sets-${c.exerciseId}'),
            columnWidths: const {0: FixedColumnWidth(48), 3: FixedColumnWidth(56)},
            children: [
              TableRow(
                decoration: BoxDecoration(border: Border(bottom: BorderSide(color: colors.line))),
                children: [
                  for (final (i, h) in [l.cmpColSet, l.progressLegendToday, l.cmpColLast, l.cmpColDiff].indexed)
                    pad(
                      Text(h, style: TextStyle(fontSize: 12, color: colors.fg2, fontWeight: FontWeight.w600)),
                      a: i == 3 ? Alignment.centerRight : Alignment.centerLeft,
                    ),
                ],
              ),
              for (final r in rows)
                TableRow(
                  decoration: BoxDecoration(border: Border(bottom: BorderSide(color: colors.line.withValues(alpha: 0.5)))),
                  children: [
                    pad(Text('${r.number}', style: cell(color: colors.fg2))),
                    pad(
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (r.fail) ...[
                            Icon(Icons.warning_amber_rounded, key: Key('fail-${c.exerciseId}-${r.number}'), size: 16, color: colors.fail),
                            const SizedBox(width: 2),
                          ],
                          Text(setText(r.today), style: cell(color: r.fail ? colors.fail : null)),
                          if (r.pr) ...[
                            const SizedBox(width: 4),
                            Icon(Icons.star_rounded, key: Key('pr-${c.exerciseId}-${r.number}'), size: 16, color: colors.pr),
                          ],
                        ],
                      ),
                    ),
                    pad(Text(setText(r.previous), style: cell(color: colors.fg2))),
                    pad(
                      Text(
                        r.diffReps == null
                            ? '-'
                            : r.diffReps! > 0
                            ? '+${r.diffReps}'
                            : r.diffReps! < 0
                            ? '\u2212${-r.diffReps!}'
                            : '0',
                        style: cell(color: r.fail ? colors.fail : ((r.diffReps ?? 0) > 0 ? colors.accentStrong : colors.fg2)),
                      ),
                      a: Alignment.centerRight,
                    ),
                  ],
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// 추이: 추정 1RM 꺾은선(최근 12회) + 한 줄 요약.
class _TrendView extends ConsumerWidget {
  const _TrendView({super.key, required this.exerciseId});
  final String exerciseId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final colors = AppColors.of(context);
    final unit = ref.watch(settingsProvider).weightUnit;
    final async = ref.watch(exerciseProgressProvider((exerciseId: exerciseId, period: ProgressPeriod.y1)));
    if (async.hasError) {
      final offline = async.error is ApiException && (async.error as ApiException).isNetwork;
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Text(offline ? l.progressOffline : l.progressLoadFailed, key: const Key('trend-error'), textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () => ref.invalidate(exerciseProgressProvider((exerciseId: exerciseId, period: ProgressPeriod.y1))),
              child: Text(l.commonRetry),
            ),
          ],
        ),
      );
    }
    final data = async.value;
    if (data == null) return const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()));
    final pts = recentE1rmPoints(data.points);
    if (pts.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(l.progressEmpty, key: const Key('trend-empty'), textAlign: TextAlign.center),
      );
    }
    String md(DateTime d) => '${d.toLocal().month}/${d.toLocal().day}';
    double disp(double kg) => Units.toDisplay(kg, unit);
    String num1(double v) {
      final s = v.toStringAsFixed(1);
      return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
    }

    final last = pts.last;
    final prs = pts.where((p) => p.isPr).length;
    final unitText = unit == WeightUnit.KG ? 'kg' : 'lb';
    final formula = switch (data.formula) {
      'BRZYCKI' => l.settingsE1rmBrzycki,
      'LOMBARDI' => l.settingsE1rmLombardi,
      _ => l.settingsE1rmEpley,
    };
    final setText = '${Units.format(last.topWeightKg, unit, withUnit: false)}\u00d7${last.topReps}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        E1rmTrendChart(
          key: const Key('trend-chart'),
          points: [
            for (var i = 0; i < pts.length; i++)
              TrendPoint(disp(pts[i].yKg), i == pts.length - 1 ? l.cmpToday(md(pts[i].date)) : md(pts[i].date), pts[i].isPr),
          ],
          valueLabel: num1,
          unitLabel: unitText,
          semantics: l.cmpTrendSemantics,
        ),
        _Legend(
          items: [
            (LegendKind.line, l.cmpLegendE1rm),
            (LegendKind.star, l.progressLegendPr),
            (LegendKind.ring, l.cmpLegendLatest),
          ],
        ),
        Card(
          key: const Key('trend-summary'),
          color: colors.surface2,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: '${num1(disp(last.yKg))}$unitText', style: const TextStyle(fontWeight: FontWeight.w700)),
                  TextSpan(text: l.cmpTrendRest(md(last.date), setText, formula, pts.length, prs)),
                ],
              ),
              style: const TextStyle(fontSize: 14),
            ),
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            key: const Key('trend-open-progress'),
            onPressed: () => context.push(Routes.exerciseProgress(exerciseId)),
            child: Text(l.progressButton),
          ),
        ),
      ],
    );
  }
}
