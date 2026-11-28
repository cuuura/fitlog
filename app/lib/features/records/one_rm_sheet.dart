// 1RM 측정 추가 시트. 종목 기록 화면과 MY의 3대 운동 화면이 함께 쓴다.
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/dto.dart';
import '../../core/api/program_dto.dart' show OneRmMeasurement;
import '../../core/big3.dart';
import '../../core/clock.dart';
import '../../core/ids.dart';
import '../../core/settings/settings_controller.dart';
import '../../core/ui/form_sheet.dart';
import '../../core/units.dart';
import '../../data/providers.dart';
import '../../l10n/gen/app_localizations.dart';
import '../progress/exercise_progress_page.dart' show exerciseProgressProvider;
import '../session/session_format.dart';
import 'exercise_records_page.dart' show exerciseRecordsProvider, oneRmListProvider;

/// 측정 추가 시트를 연다. 저장하면 true. [choices](3대 종목 id)가 있으면 맨 위 칩으로 종목을 바꿀 수 있다.
/// 저장 성공 시 그 종목의 기록·측정 목록·추이를 다시 불러오게 한다.
Future<bool?> showAddOneRmSheet(BuildContext context, {required String exerciseId, List<String>? choices}) {
  return showFormSheet<bool>(
    context,
    builder: (_) => AddOneRmSheet(exerciseId: exerciseId, choices: choices),
  );
}

class AddOneRmSheet extends ConsumerStatefulWidget {
  const AddOneRmSheet({super.key, required this.exerciseId, this.choices});
  final String exerciseId;
  final List<String>? choices;
  @override
  ConsumerState<AddOneRmSheet> createState() => _AddOneRmSheetState();
}

class _AddOneRmSheetState extends ConsumerState<AddOneRmSheet> {
  final _weight = TextEditingController();
  final _note = TextEditingController();
  late DateTime _date;
  late String _exerciseId;
  bool _bad = false;

  @override
  void initState() {
    super.initState();
    _exerciseId = widget.exerciseId;
    _date = ref.read(clockProvider)().toLocal();
  }

  @override
  void dispose() {
    _weight.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime(_date.year + 1),
    );
    if (d != null) setState(() => _date = DateTime(d.year, d.month, d.day, _date.hour, _date.minute));
  }

  /// 검증 실패면 null(시트 유지). 저장이 실패하면 예외가 FormSheet까지 올라가 입력이 남는다.
  Future<bool?> _submit() async {
    final unit = ref.read(settingsProvider).weightUnit;
    final v = double.tryParse(_weight.text.trim().replaceAll(',', '.'));
    if (v == null || v <= 0) {
      setState(() => _bad = true);
      return null;
    }
    setState(() => _bad = false);
    final note = _note.text.trim();
    await ref.read(recordsRepositoryProvider).addOneRm(
      _exerciseId,
      OneRmMeasurement(
        id: newId(),
        weightKg: Units.fromDisplay(v, unit),
        measuredAt: _date.toUtc(),
        note: note.isEmpty ? null : note,
      ),
    );
    ref.invalidate(exerciseRecordsProvider(_exerciseId));
    ref.invalidate(oneRmListProvider(_exerciseId));
    ref.invalidate(exerciseProgressProvider); // 기간별 추이 전부
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final unit = ref.watch(settingsProvider).weightUnit;
    final choices = widget.choices;
    final prev = ref.watch(exerciseRecordsProvider(_exerciseId)).value?.latestMeasured;
    return FormSheet<bool>(
      title: choices == null ? l.recordsOneRmAdd : l.big3SheetTitle,
      submitLabel: l.commonAdd,
      submitKey: const Key('onerm-save'),
      failureMessage: (_) => l.recordsActionFailed,
      onSubmit: _submit,
      children: [
        if (choices != null)
          Wrap(
            spacing: 8,
            children: [
              for (final id in choices)
                ChoiceChip(
                  key: Key('onerm-lift-$id'),
                  label: Text(big3Lifts.where((b) => b.id == id).firstOrNull?.shortName(l) ?? id),
                  selected: _exerciseId == id,
                  onSelected: (_) => setState(() => _exerciseId = id),
                ),
            ],
          ),
        TextField(
          key: const Key('onerm-weight'),
          controller: _weight,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
          decoration: InputDecoration(
            labelText: l.recordsOneRmWeight(unit == WeightUnit.KG ? 'kg' : 'lb'),
            errorText: _bad ? l.recordsInvalidWeight : null,
            helperText: prev == null
                ? null
                : l.big3PrevMeasured(Units.format(prev.weightKg, unit), shortDate(prev.measuredAt.toLocal())),
          ),
        ),
        ListTile(
          key: const Key('onerm-date'),
          contentPadding: EdgeInsets.zero,
          title: Text(l.recordsOneRmDate),
          trailing: Text(formatDate(_date)),
          onTap: _pickDate,
        ),
        TextField(
          key: const Key('onerm-note'),
          controller: _note,
          decoration: InputDecoration(labelText: l.recordsOneRmNote),
        ),
      ],
    );
  }
}
