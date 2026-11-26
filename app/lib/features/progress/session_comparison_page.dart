// B1 소유(v1.0). STA-4 오늘 vs 지난 같은 세션·이전 PR 막대.
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/api_client.dart' show ApiException;
import '../../core/api/stats_dto.dart';
import '../../core/settings/settings_controller.dart';
import '../../core/units.dart';
import '../../data/providers.dart';
import '../../l10n/gen/app_localizations.dart';
import '../exercise_picker/exercise_labels.dart';
import '../session/session_controller.dart' show exerciseMapProvider;
import 'progress_logic.dart';

final sessionComparisonProvider = FutureProvider.autoDispose.family<SessionComparison, String>((ref, id) async {
  // 방금 끝낸 세션은 아직 서버에 없을 수 있다. 먼저 동기화를 시도한다(실패해도 진행).
  try {
    await ref.read(syncServiceProvider).syncNow().timeout(const Duration(seconds: 8));
  } catch (_) {}
  return ref.watch(statsRepositoryProvider).comparison(id);
}, retry: (_, _) => null);

class SessionComparisonPage extends ConsumerStatefulWidget {
  const SessionComparisonPage({super.key, required this.sessionId});
  final String sessionId;

  @override
  ConsumerState<SessionComparisonPage> createState() => _SessionComparisonPageState();
}

class _SessionComparisonPageState extends ConsumerState<SessionComparisonPage> {
  CompareMetric _metric = CompareMetric.weight;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final async = ref.watch(sessionComparisonProvider(widget.sessionId));

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
      body = ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<CompareMetric>(
              key: const Key('compare-metric'),
              showSelectedIcon: false,
              segments: [
                ButtonSegment(
                  value: CompareMetric.weight,
                  label: Text(l.progressMetricWeight, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
                ButtonSegment(
                  value: CompareMetric.e1rm,
                  label: Text(l.progressMetricE1rm, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
                ButtonSegment(
                  value: CompareMetric.volume,
                  label: Text(l.progressMetricVolume, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              ],
              selected: {_metric},
              onSelectionChanged: (s) => setState(() => _metric = s.first),
            ),
          ),
          const SizedBox(height: 12),
          for (final c in data.exercises)
            _ExerciseCard(key: Key('compare-card-${c.exerciseId}'), c: c, metric: _metric),
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(l.progressCompareTitle)),
      body: body,
    );
  }
}

class _ExerciseCard extends ConsumerWidget {
  const _ExerciseCard({super.key, required this.c, required this.metric});
  final ExerciseComparison c;
  final CompareMetric metric;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final unit = ref.watch(settingsProvider).weightUnit;
    final ex = ref.watch(exerciseMapProvider).value?[c.exerciseId];
    final name = ex == null ? c.exerciseId : exerciseDisplayName(context, ex);
    final bars = barGroup(c, metric);
    final rows = setRows(c);
    final badges = prBadges(c);
    final cs = theme.colorScheme;

    Color colorOf(BarKind k) => switch (k) {
      BarKind.previous => cs.outline,
      BarKind.today => cs.primary,
      BarKind.previousPr => cs.tertiary,
    };
    String labelOf(BarKind k) => switch (k) {
      BarKind.previous => l.progressLegendPrevious,
      BarKind.today => l.progressLegendToday,
      BarKind.previousPr => l.progressLegendPrevPr,
    };
    String fmt(double kg) => Units.format(kg, unit);
    String setText(SnapSet? s) => s == null ? '-' : '${Units.format(s.weightKg, unit, withUnit: false)}×${s.reps}';

    final maxV = bars.isEmpty ? 1.0 : bars.map((b) => Units.toDisplay(b.valueKg, unit)).reduce((a, b) => a > b ? a : b);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(name, style: theme.textTheme.titleMedium),
                if (c.previous == null) Chip(key: Key('first-${c.exerciseId}'), label: Text(l.progressFirstRecord)),
                if (badges.weight) Chip(key: Key('pr-weight-${c.exerciseId}'), label: Text(l.progressWeightPrBadge)),
                if (badges.e1rm) Chip(key: Key('pr-e1rm-${c.exerciseId}'), label: Text(l.progressE1rmPrBadge)),
              ],
            ),
            const SizedBox(height: 12),
            if (bars.isEmpty)
              Text(l.progressCompareEmpty)
            else ...[
              SizedBox(
                height: 160,
                child: BarChart(
                  BarChartData(
                    maxY: maxV * 1.2,
                    minY: 0,
                    gridData: const FlGridData(drawVerticalLine: false),
                    borderData: FlBorderData(show: false),
                    titlesData: FlTitlesData(
                      topTitles: const AxisTitles(),
                      rightTitles: const AxisTitles(),
                      leftTitles: const AxisTitles(),
                      bottomTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 24,
                          getTitlesWidget: (v, meta) {
                            final i = v.toInt();
                            if (i < 0 || i >= bars.length) return const SizedBox.shrink();
                            return SideTitleWidget(
                              meta: meta,
                              child: Text(fmt(bars[i].valueKg), style: theme.textTheme.labelSmall),
                            );
                          },
                        ),
                      ),
                    ),
                    barTouchData: BarTouchData(enabled: false),
                    barGroups: [
                      for (var i = 0; i < bars.length; i++)
                        BarChartGroupData(
                          x: i,
                          barRods: [
                            BarChartRodData(
                              toY: Units.toDisplay(bars[i].valueKg, unit),
                              color: colorOf(bars[i].kind),
                              width: 28,
                              borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 16,
                runSpacing: 4,
                children: [for (final b in bars) _Legend(color: colorOf(b.kind), label: labelOf(b.kind))],
              ),
            ],
            if (rows.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(l.progressSetsHeader, style: theme.textTheme.labelLarge),
              const SizedBox(height: 4),
              Table(
                key: Key('compare-sets-${c.exerciseId}'),
                columnWidths: const {0: FlexColumnWidth(1.2)},
                children: [
                  TableRow(
                    children: [
                      const SizedBox.shrink(),
                      Text(l.progressLegendPrevious, style: theme.textTheme.labelSmall),
                      Text(l.progressLegendToday, style: theme.textTheme.labelSmall),
                    ],
                  ),
                  for (final r in rows)
                    TableRow(
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Text(l.progressSetLabel(r.number)),
                        ),
                        Text(setText(r.previous)),
                        Text(setText(r.today)),
                      ],
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label});
  final Color color;
  final String label;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      const SizedBox(width: 6),
      Text(label, style: Theme.of(context).textTheme.bodySmall),
    ],
  );
}
