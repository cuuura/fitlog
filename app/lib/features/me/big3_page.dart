// MY 탭 아래 '3대 운동 1RM' 화면: 현재 1RM·합계와 측정/추정 추이 그래프, 측정 추가.
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/api_client.dart' show ApiException;
import '../../core/api/dto.dart' show WeightUnit;
import '../../core/big3.dart';
import '../../core/clock.dart';
import '../../core/routes.dart';
import '../../core/settings/settings_controller.dart';
import '../../core/theme.dart';
import '../../core/units.dart';
import '../../l10n/gen/app_localizations.dart';
import '../exercise_picker/exercise_labels.dart';
import '../progress/exercise_progress_page.dart' show RingDot, exerciseProgressProvider;
import '../progress/progress_logic.dart';
import '../records/exercise_records_page.dart' show exerciseRecordsProvider, formulaLabel, oneRmListProvider;
import '../records/one_rm_sheet.dart';
import '../session/session_controller.dart' show exerciseMapProvider;
import '../session/session_format.dart';
import 'big3_logic.dart';

/// 3대 종목의 현재 1RM(측정 우선·없으면 추정). 한 종목이라도 못 불러오면 오류.
final big3CurrentsProvider = FutureProvider.autoDispose<List<Big3Current?>>((ref) async {
  final rs = await Future.wait([for (final id in big3Ids) ref.watch(exerciseRecordsProvider(id).future)]);
  return [for (final r in rs) big3Current(r)];
}, retry: (_, _) => null);

/// "합계 422.5 kg (추정 포함)" / "2개 입력됨" / 안내.
String big3TotalLabel(AppLocalizations l, Big3Total t, WeightUnit unit) {
  if (t.kg != null) {
    final v = Units.format(t.kg!, unit);
    return t.includesEstimate ? l.big3TotalEstimated(v) : l.big3TotalExact(v);
  }
  return t.count == 0 ? l.big3TotalNone : l.big3TotalPartial(t.count);
}

bool isOfflineError(Object? e) => e is ApiException && e.isNetwork;

class Big3Page extends ConsumerStatefulWidget {
  const Big3Page({super.key});

  @override
  ConsumerState<Big3Page> createState() => _Big3PageState();
}

class _Big3PageState extends ConsumerState<Big3Page> {
  int _lift = 0;
  ProgressPeriod _period = ProgressPeriod.m6;
  ({bool measured, DateTime date})? _sel;

  String get _id => big3Lifts[_lift].id;

  String _periodLabel(AppLocalizations l, ProgressPeriod p) => switch (p) {
    ProgressPeriod.m3 => l.progressPeriod3m,
    ProgressPeriod.m6 => l.progressPeriod6m,
    ProgressPeriod.y1 => l.progressPeriod1y,
    ProgressPeriod.all => l.progressPeriodAll,
  };

  Future<void> _add(String id) => showAddOneRmSheet(context, exerciseId: id, choices: big3Ids);

  /// 종목 기록 화면에서 돌아오면 거기서 바뀐 값을 다시 불러온다.
  Future<void> _openRecords(String id) async {
    await context.push(Routes.exerciseRecords(id));
    if (!mounted) return;
    ref.invalidate(exerciseRecordsProvider(id));
    ref.invalidate(oneRmListProvider(id));
    ref.invalidate(exerciseProgressProvider);
  }

  void _retry() {
    ref.invalidate(big3CurrentsProvider);
    for (final id in big3Ids) {
      ref.invalidate(exerciseRecordsProvider(id));
    }
    ref.invalidate(oneRmListProvider(_id));
    ref.invalidate(exerciseProgressProvider);
  }

  Widget _errorBox(AppLocalizations l, Object? err) {
    final offline = isOfflineError(err);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          Text(
            offline ? l.progressOffline : l.progressLoadFailed,
            key: Key(offline ? 'big3-offline' : 'big3-error'),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          OutlinedButton(key: const Key('big3-retry'), onPressed: _retry, child: Text(l.commonRetry)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = AppColors.of(context);
    final unit = ref.watch(settingsProvider).weightUnit;
    final currents = ref.watch(big3CurrentsProvider);
    final names = ref.watch(exerciseMapProvider).value;

    Widget row(int i) {
      final lift = big3Lifts[i];
      final cur = currents.value?[i];
      final name = names?[lift.id] == null ? lift.fullName(l) : exerciseDisplayName(context, names![lift.id]!);
      final src = cur == null
          ? null
          : cur.measured
          ? l.big3RowMeasured(formatDate(cur.date.toLocal()))
          : l.big3RowEstimated(Units.format(cur.estWeightKg ?? 0, unit), cur.estReps ?? 0, formulaLabel(l, cur.formula ?? 'EPLEY'));
      return InkWell(
        key: Key('big3-row-${lift.key}'),
        onTap: () => _openRecords(lift.id),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 72),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                      if (src != null)
                        Text(
                          src,
                          style: TextStyle(fontSize: 13, color: cur!.measured ? c.accentStrong : c.fg2),
                        ),
                    ],
                  ),
                ),
                if (cur == null)
                  Text(
                    currents.isLoading ? '-' : l.big3NoRecord,
                    style: TextStyle(color: c.fg2, fontSize: currents.isLoading ? 24 : 14),
                  )
                else ...[
                  Text(
                    Units.format(cur.kg, unit, withUnit: false),
                    style: AppNum.style(context, 30, color: cur.measured ? null : c.fg2),
                  ),
                  const SizedBox(width: 4),
                  Text(unit == WeightUnit.KG ? 'kg' : 'lb', style: TextStyle(color: c.fg2)),
                ],
                const SizedBox(width: 4),
                IconButton(
                  key: Key('big3-add-${lift.key}'),
                  tooltip: l.big3AddTooltip(lift.shortName(l)),
                  style: IconButton.styleFrom(backgroundColor: c.accentSoft, foregroundColor: c.accentStrong),
                  icon: const Icon(Icons.add),
                  onPressed: () => _add(lift.id),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final total = currents.value == null ? null : big3Total(currents.value!);

    return ScaffoldMessenger(
      child: Scaffold(
        appBar: AppBar(title: Text(l.big3Title)),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(0, 8, 0, 24),
          children: [
            if (currents.hasError)
              _errorBox(l, currents.error)
            else ...[
              Card(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(children: [for (var i = 0; i < 3; i++) row(i)]),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: Text(
                  total == null ? '' : big3TotalLabel(l, total, unit),
                  key: const Key('big3-total'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ],
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
              child: Text(l.big3TrendTitle, style: Theme.of(context).textTheme.titleSmall?.copyWith(color: c.accentStrong)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SizedBox(
                width: double.infinity,
                child: SegmentedButton<int>(
                  key: const Key('big3-lift'),
                  showSelectedIcon: false,
                  segments: [
                    for (var i = 0; i < 3; i++)
                      ButtonSegment(value: i, label: Text(big3Lifts[i].shortName(l), maxLines: 1)),
                  ],
                  selected: {_lift},
                  onSelectionChanged: (s) => setState(() {
                    _lift = s.first;
                    _sel = null;
                  }),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Wrap(
                spacing: 8,
                children: [
                  for (final p in ProgressPeriod.values)
                    ChoiceChip(
                      key: Key('big3-period-${p.name}'),
                      label: Text(_periodLabel(l, p)),
                      selected: _period == p,
                      onSelected: (_) => setState(() {
                        _period = p;
                        _sel = null;
                      }),
                    ),
                ],
              ),
            ),
            _trend(context, l, unit),
          ],
        ),
      ),
    );
  }

  Widget _trend(BuildContext context, AppLocalizations l, WeightUnit unit) {
    final c = AppColors.of(context);
    final ms = ref.watch(oneRmListProvider(_id));
    final prog = ref.watch(exerciseProgressProvider((exerciseId: _id, period: _period)));
    final err = ms.hasError ? ms.error : (prog.hasError ? prog.error : null);
    if (ms.hasError || prog.hasError) return _errorBox(l, err);
    if (ms.value == null || prog.value == null) {
      return const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()));
    }
    final now = ref.read(clockProvider)();
    final data = big3Chart(
      measurements: ms.value!,
      progress: prog.value!.points,
      from: progressFrom(_period, now),
    );
    if (data.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(l.big3Empty, key: const Key('big3-empty'), textAlign: TextAlign.center),
      );
    }

    final theme = Theme.of(context);
    final labelStyle = theme.textTheme.labelSmall;
    double disp(double kg) => Units.toDisplay(kg, unit);
    final range = yRange(data.ys.map(disp));
    final all = data.all;
    final sel = (_sel == null
            ? null
            : all.where((d) => d.measured == _sel!.measured && d.date == _sel!.date).firstOrNull) ??
        all.last;
    final latest = data.latestMeasured;

    // 막대 순서: 측정, 추정(비어 있는 계열은 넣지 않는다).
    final series = [if (data.measured.isNotEmpty) data.measured, if (data.estimated.isNotEmpty) data.estimated];

    LineChartBarData bar(List<Big3Dot> dots) {
      final measured = dots.first.measured;
      final color = measured ? c.accentStrong : c.last;
      return LineChartBarData(
        spots: [for (final d in dots) FlSpot(d.x, disp(d.kg))],
        color: color,
        barWidth: measured ? 2.5 : 2,
        isCurved: false,
        dashArray: measured ? null : [5, 4],
        dotData: FlDotData(
          getDotPainter: (spot, _, _, i) => RingDot(
            fill: measured ? color : theme.colorScheme.surface,
            stroke: color,
            ring: measured && identical(dots[i], latest),
          ),
        ),
      );
    }

    String fmt(double kg) => Units.format(kg, unit);
    final interval = data.maxX / 3;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: SizedBox(
            height: 240,
            child: LineChart(
              key: const Key('big3-chart'),
              LineChartData(
                minY: range.min,
                maxY: range.max,
                minX: 0,
                maxX: data.maxX,
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
                          : SideTitleWidget(meta: meta, child: Text(meta.formattedValue, style: labelStyle)),
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      interval: interval,
                      reservedSize: 28,
                      getTitlesWidget: (v, meta) {
                        final o = data.origin;
                        if (o == null) return const SizedBox.shrink();
                        final d = o.add(Duration(minutes: (v * 24 * 60).round())).toLocal();
                        return SideTitleWidget(meta: meta, child: Text(shortDate(d), style: labelStyle));
                      },
                    ),
                  ),
                ),
                lineTouchData: LineTouchData(
                  touchCallback: (event, resp) {
                    final spot = resp?.lineBarSpots?.firstOrNull;
                    if (event is FlTapUpEvent && spot != null) {
                      final d = series[spot.barIndex][spot.spotIndex];
                      setState(() => _sel = (measured: d.measured, date: d.date));
                    }
                  },
                  touchTooltipData: LineTouchTooltipData(getTooltipItems: (spots) => [for (final _ in spots) null]),
                ),
                lineBarsData: [for (final s in series) bar(s)],
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Wrap(
            spacing: 16,
            runSpacing: 4,
            children: [
              _Legend(color: c.accentStrong, dashed: false, filled: true, label: l.big3LegendMeasured),
              _Legend(color: c.last, dashed: true, filled: false, label: l.big3LegendEstimated),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Card(
            key: const Key('big3-selected'),
            margin: EdgeInsets.zero,
            child: ListTile(
              title: Text(
                (sel.measured ? l.big3SelMeasured : l.big3SelEstimated)(shortDate(sel.date.toLocal()), fmt(sel.kg)),
                // 한글이 섞인 문장이라 숫자 전용 글꼴(AppNum)은 쓰지 않는다.
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              trailing: TextButton(
                key: const Key('big3-open-records'),
                onPressed: () => _openRecords(_id),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [Text(l.big3OpenRecords), const Icon(Icons.chevron_right, size: 18)],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 범례: 선 모양(실선/점선)과 점 모양(채움/속 빈)으로도 구분한다.
class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.dashed, required this.filled, required this.label});
  final Color color;
  final bool dashed, filled;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      SizedBox(
        width: 28,
        height: 12,
        child: CustomPaint(
          painter: _LegendPainter(color, dashed, filled, Theme.of(context).colorScheme.surface),
        ),
      ),
      const SizedBox(width: 6),
      Text(label, style: Theme.of(context).textTheme.bodySmall),
    ],
  );
}

class _LegendPainter extends CustomPainter {
  _LegendPainter(this.color, this.dashed, this.filled, this.surface);
  final Color color, surface;
  final bool dashed, filled;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    final line = Paint()
      ..color = color
      ..strokeWidth = 2;
    if (dashed) {
      for (var x = 0.0; x < size.width; x += 9) {
        canvas.drawLine(Offset(x, y), Offset((x + 5).clamp(0, size.width), y), line);
      }
    } else {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
    }
    final c = Offset(size.width / 2, y);
    canvas.drawCircle(c, 4, Paint()..color = filled ? color : surface);
    canvas.drawCircle(
      c,
      4,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_LegendPainter o) =>
      o.color != color || o.dashed != dashed || o.filled != filled || o.surface != surface;
}
