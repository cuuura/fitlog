// B1 소유(v1.0). STA-4 종목 추이 꺾은선.
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/api_client.dart' show ApiException;
import '../../core/api/stats_dto.dart';
import '../../core/clock.dart';
import '../../core/routes.dart';
import '../../core/settings/settings_controller.dart';
import '../../core/units.dart';
import '../../data/providers.dart';
import '../../l10n/gen/app_localizations.dart';
import '../exercise_picker/exercise_labels.dart';
import '../session/session_controller.dart' show exerciseMapProvider;
import '../session/session_format.dart';
import 'progress_logic.dart';

typedef ProgressKey = ({String exerciseId, ProgressPeriod period});

final exerciseProgressProvider = FutureProvider.autoDispose.family<ExerciseProgress, ProgressKey>((ref, key) {
  final now = ref.read(clockProvider)();
  return ref
      .watch(statsRepositoryProvider)
      .progress(key.exerciseId, from: progressFrom(key.period, now), limit: progressLimit);
}, retry: (_, _) => null);

class ExerciseProgressPage extends ConsumerStatefulWidget {
  const ExerciseProgressPage({super.key, required this.exerciseId});
  final String exerciseId;

  @override
  ConsumerState<ExerciseProgressPage> createState() => _ExerciseProgressPageState();
}

class _ExerciseProgressPageState extends ConsumerState<ExerciseProgressPage> {
  ProgressPeriod _period = ProgressPeriod.m6;
  ProgressMetric _metric = ProgressMetric.weight;
  int? _selected;

  ProgressKey get _key => (exerciseId: widget.exerciseId, period: _period);

  String _periodLabel(AppLocalizations l, ProgressPeriod p) => switch (p) {
    ProgressPeriod.m3 => l.progressPeriod3m,
    ProgressPeriod.m6 => l.progressPeriod6m,
    ProgressPeriod.y1 => l.progressPeriod1y,
    ProgressPeriod.all => l.progressPeriodAll,
  };

  String _metricLabel(AppLocalizations l, ProgressMetric m) => switch (m) {
    ProgressMetric.weight => l.progressMetricWeight,
    ProgressMetric.e1rm => l.progressMetricE1rm,
    ProgressMetric.volume => l.progressMetricVolume,
  };

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final ex = ref.watch(exerciseMapProvider).value?[widget.exerciseId];
    final async = ref.watch(exerciseProgressProvider(_key));

    Widget body;
    if (async.hasError) {
      final err = async.error;
      final offline = err is ApiException && err.isNetwork;
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                offline ? l.progressOffline : l.progressLoadFailed,
                key: Key(offline ? 'progress-offline' : 'progress-error'),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                key: const Key('progress-retry'),
                onPressed: () => ref.invalidate(exerciseProgressProvider(_key)),
                child: Text(l.commonRetry),
              ),
            ],
          ),
        ),
      );
    } else if (async.value == null) {
      body = const Center(child: CircularProgressIndicator());
    } else {
      body = _content(context, l, async.value!);
    }

    return Scaffold(
      appBar: AppBar(title: Text(ex == null ? l.progressTitle : exerciseDisplayName(context, ex))),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Wrap(
              spacing: 8,
              children: [
                for (final p in ProgressPeriod.values)
                  ChoiceChip(
                    key: Key('progress-period-${p.name}'),
                    label: Text(_periodLabel(l, p)),
                    selected: _period == p,
                    onSelected: (_) => setState(() {
                      _period = p;
                      _selected = null;
                    }),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: SizedBox(
              width: double.infinity,
              child: SegmentedButton<ProgressMetric>(
                key: const Key('progress-metric'),
                showSelectedIcon: false,
                segments: [
                  for (final m in ProgressMetric.values)
                    ButtonSegment(
                      value: m,
                      label: Text(_metricLabel(l, m), maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                ],
                selected: {_metric},
                onSelectionChanged: (s) => setState(() {
                  _metric = s.first;
                  _selected = null;
                }),
              ),
            ),
          ),
          Expanded(child: body),
        ],
      ),
    );
  }

  Widget _content(BuildContext context, AppLocalizations l, ExerciseProgress data) {
    final unit = ref.watch(settingsProvider).weightUnit;
    final points = chartPoints(data.points, _metric);
    if (points.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(l.progressEmpty, key: const Key('progress-empty'), textAlign: TextAlign.center),
        ),
      );
    }
    final theme = Theme.of(context);
    final normal = theme.colorScheme.primary;
    final prColor = theme.colorScheme.tertiary;
    final isVolume = _metric == ProgressMetric.volume;
    double disp(double kg) => Units.toDisplay(kg, unit);
    String fmt(double kg) => Units.format(kg, unit);

    final bestKg = bestLineKg(data, _metric);
    final range = yRange([for (final p in points) disp(p.yKg), ?(bestKg == null ? null : disp(bestKg))]);
    final sel = points[(_selected ?? points.length - 1).clamp(0, points.length - 1)];
    final hasPr = points.any((p) => p.isPr);

    String describe(ChartPoint p) {
      final date = formatDate(p.date.toLocal());
      final value = switch (_metric) {
        ProgressMetric.weight => l.progressWeightReps(fmt(p.topWeightKg), p.topReps),
        _ => fmt(p.yKg),
      };
      return l.progressSelected(date, value);
    }

    final labelStyle = theme.textTheme.labelSmall;
    final step = (points.length / 4).ceil().clamp(1, points.length);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SizedBox(
          height: 260,
          child: LineChart(
            key: const Key('progress-chart'),
            LineChartData(
              minY: range.min,
              maxY: range.max,
              minX: 0,
              maxX: points.length == 1 ? 1 : (points.length - 1).toDouble(),
              gridData: const FlGridData(drawVerticalLine: false),
              borderData: FlBorderData(show: false),
              titlesData: FlTitlesData(
                topTitles: const AxisTitles(),
                rightTitles: const AxisTitles(),
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 44,
                    getTitlesWidget: (v, meta) => (v == meta.min || v == meta.max)
                        ? const SizedBox.shrink()
                        : SideTitleWidget(
                            meta: meta,
                            child: Text(meta.formattedValue, style: labelStyle),
                          ),
                  ),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    interval: 1,
                    reservedSize: 28,
                    getTitlesWidget: (v, meta) {
                      final i = v.round();
                      if (v != i.toDouble() || i < 0 || i >= points.length || i % step != 0) {
                        return const SizedBox.shrink();
                      }
                      final d = points[i].date.toLocal();
                      return SideTitleWidget(
                        meta: meta,
                        child: Text('${d.month}/${d.day}', style: labelStyle),
                      );
                    },
                  ),
                ),
              ),
              extraLinesData: ExtraLinesData(
                horizontalLines: [
                  if (bestKg != null)
                    HorizontalLine(
                      y: disp(bestKg),
                      color: theme.colorScheme.outline,
                      strokeWidth: 1.5,
                      dashArray: [6, 4],
                      label: HorizontalLineLabel(
                        show: true,
                        alignment: Alignment.topRight,
                        style: labelStyle,
                        labelResolver: (_) => l.progressBestLine(fmt(bestKg)),
                      ),
                    ),
                ],
              ),
              lineTouchData: LineTouchData(
                touchCallback: (event, resp) {
                  final spot = resp?.lineBarSpots?.firstOrNull;
                  if (event is FlTapUpEvent && spot != null) setState(() => _selected = spot.spotIndex);
                },
                touchTooltipData: LineTouchTooltipData(
                  getTooltipItems: (spots) => [
                    for (final s in spots)
                      LineTooltipItem(
                        describe(points[s.spotIndex]),
                        TextStyle(color: theme.colorScheme.onInverseSurface),
                      ),
                  ],
                ),
              ),
              lineBarsData: [
                LineChartBarData(
                  spots: [for (final p in points) FlSpot(p.index.toDouble(), disp(p.yKg))],
                  color: normal,
                  barWidth: 2,
                  isCurved: false,
                  dotData: FlDotData(
                    getDotPainter: (spot, _, _, i) => FlDotCirclePainter(
                      radius: points[i].isPr ? 6 : 4,
                      color: points[i].isPr ? prColor : normal,
                      strokeWidth: 1.5,
                      strokeColor: theme.colorScheme.surface,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 16,
          runSpacing: 4,
          children: [
            _LegendDot(color: normal, label: l.progressLegendNormal),
            if (!isVolume && hasPr) _LegendDot(color: prColor, label: l.progressLegendPr),
            if (bestKg != null) _LegendDash(color: theme.colorScheme.outline, label: l.progressLegendBest),
          ],
        ),
        const SizedBox(height: 16),
        Card(
          key: const Key('progress-selected'),
          child: ListTile(
            title: Text(describe(sel)),
            leading: sel.isPr ? Icon(Icons.emoji_events, color: prColor) : null,
            trailing: TextButton(
              key: const Key('progress-open-session'),
              onPressed: () => context.push(Routes.sessionDetail(sel.sessionId)),
              child: Text(l.progressOpenSession),
            ),
          ),
        ),
      ],
    );
  }
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color, required this.label});
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

class _LegendDash extends StatelessWidget {
  const _LegendDash({required this.color, required this.label});
  final Color color;
  final String label;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      SizedBox(width: 16, height: 10, child: CustomPaint(painter: _DashPainter(color))),
      const SizedBox(width: 6),
      Text(label, style: Theme.of(context).textTheme.bodySmall),
    ],
  );
}

class _DashPainter extends CustomPainter {
  _DashPainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 1.5;
    canvas.drawLine(Offset(0, size.height / 2), Offset(6, size.height / 2), p);
    canvas.drawLine(Offset(10, size.height / 2), Offset(size.width, size.height / 2), p);
  }

  @override
  bool shouldRepaint(_DashPainter old) => old.color != color;
}
