import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/dto.dart';
import '../../core/clock.dart';
import '../../core/ids.dart';
import '../../core/settings/settings_controller.dart';
import '../../core/theme.dart';
import '../../core/ui/form_sheet.dart';
import '../../core/ui/row_menu.dart';
import '../../core/ui/undo.dart';
import '../../core/units.dart';
import '../../data/providers.dart';
import '../../l10n/gen/app_localizations.dart';
import '../source_badge/source_badge.dart';
import '../sync_status/sync_status_indicator.dart';
import 'profile_sheets.dart';

/// BDY-1 체중 기록(최신순, 설정 단위로 표시). 저장은 항상 kg.
class BodyWeightPage extends ConsumerStatefulWidget {
  const BodyWeightPage({super.key});

  static const minKg = 20.0;
  static const maxKg = 400.0;

  @override
  ConsumerState<BodyWeightPage> createState() => _BodyWeightPageState();
}

final _measurementsProvider = StreamProvider.autoDispose<List<BodyMeasurement>>(
  (ref) => ref.watch(bodyRepositoryProvider).watchMeasurements(),
);

class _BodyWeightPageState extends ConsumerState<BodyWeightPage> {
  final _input = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final l = AppLocalizations.of(context);
    final unit = ref.read(settingsProvider).weightUnit;
    final v = double.tryParse(_input.text.trim().replaceAll(',', '.'));
    final kg = v == null ? null : Units.fromDisplay(v, unit);
    if (kg == null || kg < BodyWeightPage.minKg || kg > BodyWeightPage.maxKg) {
      setState(
        () => _error = l.bodyInvalid(
          Units.format(BodyWeightPage.minKg, unit, withUnit: false),
          Units.format(BodyWeightPage.maxKg, unit, withUnit: false),
          _unitLabel(unit),
        ),
      );
      return;
    }
    setState(() => _error = null);
    await ref
        .read(bodyRepositoryProvider)
        .add(BodyMeasurement(id: newId(), measuredAt: ref.read(clockProvider)(), weightKg: kg));
    _input.clear();
  }

  Future<void> _delete(BodyMeasurement m) async {
    final l = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final repo = ref.read(bodyRepositoryProvider);
    try {
      await repo.delete(m.id);
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(l.commonError)));
      return;
    }
    // 동기화 삭제 표시와 부딪히지 않게 새 id로 같은 값을 다시 넣는다.
    showUndoSnack(
      messenger,
      l,
      message: l.bodyDeleted,
      onUndo: () => repo.add(
        BodyMeasurement(
          id: newId(),
          measuredAt: m.measuredAt,
          weightKg: m.weightKg,
          source: m.source,
          importBatchId: m.importBatchId,
        ),
      ),
    );
  }

  Future<void> _edit(BodyMeasurement m) =>
      showFormSheet<bool>(context, builder: (_) => _EditMeasurementSheet(measurement: m));

  static String _unitLabel(WeightUnit u) => u == WeightUnit.KG ? 'kg' : 'lb';

  static String _sourceLabel(AppLocalizations l, MeasurementSource s) => switch (s) {
    MeasurementSource.HEALTH_CONNECT || MeasurementSource.HEALTHKIT => l.bodySourceHealth,
    MeasurementSource.MANUAL => l.bodySourceManual,
    _ => '',
  };

  Widget _sourceChip(BuildContext context, String text, {IconData? icon}) {
    final c = AppColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: c.surface3, borderRadius: BorderRadius.circular(12)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 12, color: c.fg2), const SizedBox(width: 4)],
          Text(
            text,
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: c.fg2),
          ),
        ],
      ),
    );
  }

  Widget _chart(BuildContext context, AppLocalizations l, List<BodyMeasurement> list, WeightUnit unit) {
    final c = AppColors.of(context);
    final latest = list.first.measuredAt;
    final from = latest.subtract(const Duration(days: 84));
    final pts = [
      for (final m in list.reversed)
        if (!m.measuredAt.isBefore(from)) m,
    ];
    if (pts.length < 2) return const SizedBox.shrink();
    final spots = [
      for (final m in pts) FlSpot(m.measuredAt.difference(from).inHours / 24.0, Units.toDisplay(m.weightKg, unit)),
    ];
    final ys = spots.map((e) => e.y);
    final minY = ys.reduce(math.min).floorToDouble() - 1;
    final maxY = ys.reduce(math.max).ceilToDouble() + 1;
    final locale = Localizations.localeOf(context).toString();
    final dfmt = DateFormat.Md(locale);
    final desc = l.bodyChartDesc(Units.format(pts.first.weightKg, unit), Units.format(pts.last.weightKg, unit));
    return Semantics(
      container: true,
      label: '${l.bodyChartTitle}. $desc',
      child: ExcludeSemantics(
        child: SizedBox(
          key: const Key('body-chart'),
          height: 160,
          child: LineChart(
            LineChartData(
              minX: 0,
              maxX: 84,
              minY: minY,
              maxY: maxY,
              gridData: FlGridData(
                drawVerticalLine: false,
                getDrawingHorizontalLine: (_) => FlLine(color: c.line, strokeWidth: 1),
              ),
              borderData: FlBorderData(show: false),
              lineTouchData: const LineTouchData(enabled: false),
              titlesData: FlTitlesData(
                topTitles: const AxisTitles(),
                rightTitles: const AxisTitles(),
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 36,
                    getTitlesWidget: (v, meta) => v == meta.min || v == meta.max
                        ? const SizedBox.shrink()
                        : Text(v.toStringAsFixed(0), style: TextStyle(fontSize: 11, color: c.fg2)),
                  ),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 22,
                    interval: 28,
                    getTitlesWidget: (v, meta) => Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        dfmt.format(from.add(Duration(days: v.round())).toLocal()),
                        style: TextStyle(fontSize: 11, color: c.fg2),
                      ),
                    ),
                  ),
                ),
              ),
              lineBarsData: [
                LineChartBarData(
                  spots: spots,
                  isCurved: false,
                  color: c.accentStrong,
                  barWidth: 2.5,
                  dotData: FlDotData(
                    getDotPainter: (spot, _, _, i) => FlDotCirclePainter(
                      radius: i == spots.length - 1 ? 5 : 3,
                      color: i == spots.length - 1 ? c.accentStrong : Theme.of(context).colorScheme.surface,
                      strokeColor: c.accentStrong,
                      strokeWidth: 2,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = AppColors.of(context);
    final settings = ref.watch(settingsProvider);
    final unit = settings.weightUnit;
    final items = ref.watch(_measurementsProvider);
    final fmt = DateFormat.yMd(Localizations.localeOf(context).toString()).add_Hm();

    Widget header(List<BodyMeasurement> list) {
      final latest = list.first;
      final weekAgo = latest.measuredAt.subtract(const Duration(days: 7));
      BodyMeasurement? ref0;
      for (final m in list) {
        if (!m.measuredAt.isAfter(weekAgo)) {
          ref0 = m;
          break;
        }
      }
      Widget? delta;
      if (ref0 != null) {
        final d = Units.toDisplay(latest.weightKg, unit) - Units.toDisplay(ref0.weightKg, unit);
        final r = (d * 10).round() / 10;
        final abs = r.abs().toStringAsFixed(1);
        final (IconData ic, String text) = r < 0
            ? (Icons.arrow_downward, l.bodyDeltaDown('$abs${_unitLabel(unit)}'))
            : r > 0
            ? (Icons.arrow_upward, l.bodyDeltaUp('$abs${_unitLabel(unit)}'))
            : (Icons.remove, l.bodyDeltaSame);
        delta = Row(
          key: const Key('body-delta'),
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(ic, size: 18, color: c.fg2),
            const SizedBox(width: 4),
            Text(text, style: TextStyle(color: c.fg2, fontSize: 14)),
          ],
        );
      }
      final h = settings.heightCm;
      final bmi = h == null ? null : latest.weightKg / ((h / 100) * (h / 100));
      final srcLabel = _sourceLabel(l, latest.source);
      Widget metric(String label, String value, String? unitText, String? src, {IconData? icon, Key? key}) => Padding(
        key: key,
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(label, style: const TextStyle(fontSize: 15)),
                  if (src != null) _sourceChip(context, src, icon: icon),
                ],
              ),
            ),
            Text(value, style: AppNum.medium(context)),
            if (unitText != null) ...[
              const SizedBox(width: 2),
              Text(unitText, style: TextStyle(color: c.fg2, fontSize: 13)),
            ],
          ],
        ),
      );
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      Units.format(latest.weightKg, unit, withUnit: false),
                      key: const Key('body-hero'),
                      style: AppNum.hero(context),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Text(_unitLabel(unit), style: TextStyle(color: c.fg2, fontSize: 18)),
                const SizedBox(width: 12),
                if (srcLabel.isNotEmpty)
                  _sourceChip(context, srcLabel, icon: srcLabel == l.bodySourceHealth ? Icons.favorite_border : null),
              ],
            ),
            if (delta != null) ...[const SizedBox(height: 4), delta],
            const SizedBox(height: 12),
            _chart(context, l, list, unit),
            const SizedBox(height: 8),
            Divider(height: 1, color: c.line),
            InkWell(
              key: const Key('body-metric-height-tap'),
              onTap: () => showHeightSheet(context, ref),
              child: h != null
                  ? metric(
                      l.bodyMetricHeight,
                      h == h.roundToDouble() ? h.toStringAsFixed(0) : '$h',
                      'cm',
                      l.bodySourceManual,
                      key: const Key('body-metric-height'),
                    )
                  : metric(l.bodyMetricHeight, l.bodyHeightEmpty, null, null, key: const Key('body-metric-height')),
            ),
            if (bmi != null) ...[
              Divider(height: 1, color: c.line),
              metric(
                l.bodyMetricBmi,
                bmi.toStringAsFixed(1),
                null,
                l.bodySourceComputed,
                key: const Key('body-metric-bmi'),
              ),
            ],
            Divider(height: 1, color: c.line),
            Padding(
              padding: const EdgeInsets.only(top: 16, bottom: 4),
              child: Text(l.bodyHistoryTitle, style: Theme.of(context).textTheme.titleSmall),
            ),
          ],
        ),
      );
    }

    Widget row(BodyMeasurement m) => ListTile(
      key: Key('body_${m.id}'),
      title: Row(
        children: [
          Text(Units.format(m.weightKg, unit)),
          if (m.source == MeasurementSource.AI_JSON ||
              m.source == MeasurementSource.AI_MCP ||
              m.source == MeasurementSource.IMPORT) ...[
            const SizedBox(width: 8),
            SourceBadge(key: Key('source-${m.id}'), source: m.source, importBatchId: m.importBatchId),
          ],
        ],
      ),
      subtitle: Text(fmt.format(m.measuredAt.toLocal())),
      onTap: () => _edit(m),
      trailing: RowMenu<String>(
        key: Key('body-menu-${m.id}'),
        items: [
          RowMenuItem(value: 'edit', label: l.commonEdit, key: const Key('body-edit')),
          RowMenuItem(value: 'delete', label: l.commonDelete, destructive: true, key: const Key('body-delete')),
        ],
        onSelected: (v) => v == 'edit' ? _edit(m) : _delete(m),
      ),
    );

    return Scaffold(
      appBar: AppBar(title: Text(l.bodyTitle), actions: const [SyncStatusIndicator()]),
      body: Column(
        children: [
          Expanded(
            child: items.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text(l.commonError)),
              data: (list) => list.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(l.bodyEmpty, textAlign: TextAlign.center),
                      ),
                    )
                  : ListView.builder(
                      itemCount: list.length + 1,
                      itemBuilder: (_, i) => i == 0 ? header(list) : row(list[i - 1]),
                    ),
            ),
          ),
          Container(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              border: Border(top: BorderSide(color: c.line)),
            ),
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextField(
                        key: const Key('bodyInput'),
                        controller: _input,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
                        decoration: InputDecoration(
                          labelText: l.bodyTodayWeight,
                          suffixText: _unitLabel(unit),
                          errorText: _error,
                          errorMaxLines: 2,
                        ),
                        onSubmitted: (_) => _add(),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: FilledButton.icon(
                        key: const Key('bodyAdd'),
                        onPressed: _add,
                        icon: const Icon(Icons.monitor_weight_outlined),
                        label: Text(l.bodyRecordAction),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 체중 기록 한 건의 무게와 측정 날짜를 고치는 시트. 시각(시·분)과 출처는 그대로 둔다.
class _EditMeasurementSheet extends ConsumerStatefulWidget {
  const _EditMeasurementSheet({required this.measurement});
  final BodyMeasurement measurement;

  @override
  ConsumerState<_EditMeasurementSheet> createState() => _EditMeasurementSheetState();
}

class _EditMeasurementSheetState extends ConsumerState<_EditMeasurementSheet> {
  late final String _initialText;
  late final TextEditingController _weight;
  late DateTime _at = widget.measurement.measuredAt.toLocal();
  String? _error;

  @override
  void initState() {
    super.initState();
    final unit = ref.read(settingsProvider).weightUnit;
    _initialText = Units.format(widget.measurement.weightKg, unit, withUnit: false);
    _weight = TextEditingController(text: _initialText);
  }

  @override
  void dispose() {
    _weight.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = ref.read(clockProvider)().toLocal();
    final today = DateTime(now.year, now.month, now.day);
    final cur = DateTime(_at.year, _at.month, _at.day);
    final d = await showDatePicker(
      context: context,
      initialDate: cur.isAfter(today) ? today : cur,
      firstDate: DateTime(2000),
      lastDate: today,
    );
    if (d == null || !mounted) return;
    setState(() => _at = DateTime(d.year, d.month, d.day, _at.hour, _at.minute, _at.second));
  }

  Future<bool?> _submit() async {
    final l = AppLocalizations.of(context);
    final unit = ref.read(settingsProvider).weightUnit;
    final text = _weight.text.trim();
    double kg;
    if (text == _initialText) {
      kg = widget.measurement.weightKg; // 안 고쳤으면 원래 값을 그대로(표시 반올림으로 흔들리지 않게)
    } else {
      final v = double.tryParse(text.replaceAll(',', '.'));
      kg = v == null ? double.nan : Units.fromDisplay(v, unit);
    }
    if (kg.isNaN || kg < BodyWeightPage.minKg || kg > BodyWeightPage.maxKg) {
      setState(
        () => _error = l.bodyInvalid(
          Units.format(BodyWeightPage.minKg, unit, withUnit: false),
          Units.format(BodyWeightPage.maxKg, unit, withUnit: false),
          unit == WeightUnit.KG ? 'kg' : 'lb',
        ),
      );
      return null;
    }
    setState(() => _error = null);
    final m = widget.measurement;
    await ref
        .read(bodyRepositoryProvider)
        .add(
          BodyMeasurement(
            id: m.id,
            measuredAt: _at.toUtc(),
            weightKg: kg,
            source: m.source,
            importBatchId: m.importBatchId,
          ),
        );
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final unit = ref.watch(settingsProvider).weightUnit;
    final dateText = DateFormat.yMd(Localizations.localeOf(context).toString()).format(_at);
    return FormSheet<bool>(
      title: l.bodyEditTitle,
      submitLabel: l.commonSave,
      submitKey: const Key('body-edit-save'),
      onSubmit: _submit,
      children: [
        TextField(
          key: const Key('body-edit-weight'),
          controller: _weight,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
          decoration: InputDecoration(
            labelText: l.bodyWeightLabel(unit == WeightUnit.KG ? 'kg' : 'lb'),
            suffixText: (unit == WeightUnit.KG ? 'kg' : 'lb'),
            errorText: _error,
            errorMaxLines: 2,
          ),
        ),
        ListTile(
          key: const Key('body-edit-date'),
          contentPadding: EdgeInsets.zero,
          title: Text(l.bodyMeasuredAt),
          subtitle: Text(dateText),
          trailing: const Icon(Icons.calendar_today_outlined),
          onTap: _pickDate,
        ),
      ],
    );
  }
}
