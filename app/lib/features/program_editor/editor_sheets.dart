// 편집기 바텀시트: 세트·종목 설정·증량 규칙. 모두 사본을 고치다가 저장하면 결과를 돌려준다.
import 'package:material_ui/material_ui.dart';

import '../../core/ui/form_sheet.dart';
import '../../l10n/gen/app_localizations.dart';
import 'editor_fields.dart';
import 'editor_text.dart';
import 'program_definition.dart';

// ---------------------------------------------------------------- 세트

Future<Json?> showSetSheet(BuildContext context, {required Json set, required bool isNew, String? error}) {
  return showFormSheet<Json>(
    context,
    builder: (_) => _SetSheet(initial: deepCopy(set), isNew: isNew, error: error),
  );
}

class _SetSheet extends StatefulWidget {
  const _SetSheet({required this.initial, required this.isNew, this.error});
  final Json initial;
  final bool isNew;
  final String? error;

  @override
  State<_SetSheet> createState() => _SetSheetState();
}

class _SetSheetState extends State<_SetSheet> {
  late final Json set = widget.initial;

  Json get load => (set['load'] ??= <String, dynamic>{'type': 'NONE'}) as Json;
  String get loadType => load['type'] is String ? load['type'] as String : 'NONE';

  void _refresh() => setState(() {});

  void _setLoadType(String t) {
    final old = loadType;
    final of = load['of'];
    final next = switch (t) {
      'PERCENT_TM' => <String, dynamic>{'type': t, 'value': 0.8},
      'FIXED' => <String, dynamic>{'type': t, 'kg': 20},
      _ => <String, dynamic>{'type': t},
    };
    if (of is String && (t == 'PERCENT_TM' || t == 'WORKING') && (old == 'PERCENT_TM' || old == 'WORKING')) {
      next['of'] = of;
    }
    if (t == 'WORKING' && old == 'WORKING' && load['value'] is num) next['value'] = load['value'];
    set['load'] = next;
    _refresh();
  }

  /// amrap·warmup·drop은 함께 쓸 수 없고, amrap은 범위(repsMax)와도 같이 쓸 수 없다.
  void _exclusive(String field, bool on) {
    for (final f in ['amrap', 'warmup', 'drop']) {
      if (f != field) set.remove(f);
    }
    if (on) {
      set[field] = true;
      if (field == 'amrap') set.remove('repsMax');
    } else {
      set.remove(field);
    }
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final lt = loadType;
    Widget flag(String field, String label) => SwitchListTile(
      key: Key('set-$field'),
      contentPadding: EdgeInsets.zero,
      title: Text(label),
      value: set[field] == true,
      onChanged: (v) => _exclusive(field, v),
    );
    return FormSheet<Json>(
      title: widget.isNew ? ET.setNew : ET.setEdit,
      submitLabel: widget.isNew ? l.commonAdd : l.commonSave,
      onSubmit: () async => set,
      children: [
        if (widget.error != null) Text(widget.error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        Row(
          children: [
            Expanded(
              child: MapNumField(key: const Key('set-count'), map: set, field: 'count', label: ET.count, integer: true),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: MapNumField(key: const Key('set-reps'), map: set, field: 'reps', label: ET.reps, integer: true),
            ),
          ],
        ),
        if (set['amrap'] != true)
          MapNumField(
            key: const Key('set-repsMax'),
            map: set,
            field: 'repsMax',
            label: ET.repsMax,
            helper: ET.repsMaxHelp,
            integer: true,
          ),
        DropdownButtonFormField<String>(
          key: Key('set-loadType-$lt'),
          initialValue: lt,
          isExpanded: true,
          decoration: const InputDecoration(isDense: true, labelText: ET.loadType, border: OutlineInputBorder()),
          items: [for (final e in ET.loadTypeNames.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
          onChanged: (v) {
            if (v != null && v != lt) _setLoadType(v);
          },
        ),
        if (lt == 'PERCENT_TM' || lt == 'WORKING')
          MapNumField(
            key: Key('set-loadValue-$lt'),
            map: load,
            field: 'value',
            label: ET.loadValuePercent,
            scale: 100,
            suffix: '%',
          ),
        if (lt == 'FIXED') MapNumField(key: const Key('set-loadKg'), map: load, field: 'kg', label: ET.loadValueKg),
        flag('amrap', ET.amrap),
        flag('warmup', ET.warmup),
        flag('drop', ET.drop),
        MapNumField(key: const Key('set-rest'), map: set, field: 'restSec', label: ET.restSec, integer: true),
        if (ProgramDef.hasWeekly(set))
          Text(ET.weeklyKept, key: const Key('set-weekly-note'), style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

// ---------------------------------------------------------------- 종목 설정

typedef ExerciseSheetResult = ({Json exercise, bool newKey});

/// 날 안 종목의 설정. [liftLabels]는 종목 키 → 화면 이름.
Future<ExerciseSheetResult?> showExerciseSheet(
  BuildContext context, {
  required Json exercise,
  required Map<String, String> liftLabels,
}) {
  return showFormSheet<ExerciseSheetResult>(
    context,
    builder: (_) => _ExerciseSheet(initial: deepCopy(exercise), liftLabels: liftLabels),
  );
}

const _newKeyValue = '__new__';

class _ExerciseSheet extends StatefulWidget {
  const _ExerciseSheet({required this.initial, required this.liftLabels});
  final Json initial;
  final Map<String, String> liftLabels;

  @override
  State<_ExerciseSheet> createState() => _ExerciseSheetState();
}

class _ExerciseSheetState extends State<_ExerciseSheet> {
  late final Json ex = widget.initial;
  late String key = ex['lift'] as String? ?? widget.liftLabels.keys.first;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return FormSheet<ExerciseSheetResult>(
      title: ET.exerciseSettings,
      submitLabel: l.commonSave,
      onSubmit: () async {
        if (key != _newKeyValue) ex['lift'] = key;
        return (exercise: ex, newKey: key == _newKeyValue);
      },
      children: [
        DropdownButtonFormField<String>(
          key: const Key('ex-liftKey'),
          initialValue: key,
          isExpanded: true,
          decoration: const InputDecoration(
            isDense: true,
            labelText: ET.liftKey,
            helperText: ET.liftKeyHelp,
            helperMaxLines: 2,
            border: OutlineInputBorder(),
          ),
          items: [
            for (final e in widget.liftLabels.entries)
              DropdownMenuItem(value: e.key, child: Text('${e.value} (${e.key})', overflow: TextOverflow.ellipsis)),
            const DropdownMenuItem(value: _newKeyValue, child: Text(ET.liftKeyNew)),
          ],
          onChanged: (v) => setState(() => key = v ?? key),
        ),
        MapSwitch(
          key: const Key('ex-accessory'),
          map: ex,
          field: 'accessory',
          label: ET.accessory,
          subtitle: ET.accessoryHelp,
          onChanged: () => setState(() {}),
        ),
        MapSwitch(
          key: const Key('ex-counts'),
          map: ex,
          field: 'countsForProgression',
          label: ET.countsForProgression,
          defaultValue: true,
          onChanged: () => setState(() {}),
        ),
        MapTextField(key: const Key('ex-superset'), map: ex, field: 'superset', label: ET.superset, maxLength: 8),
        MapNumField(key: const Key('ex-rest'), map: ex, field: 'restSec', label: ET.restSecExercise, integer: true),
      ],
    );
  }
}

// ---------------------------------------------------------------- 증량 규칙

/// 종목 키의 증량 규칙을 고친다. 돌려주는 규칙의 type이 NONE이면 규칙 없음.
Future<Json?> showRuleSheet(
  BuildContext context, {
  required String title,
  required Json? rule,
  String? error,
}) {
  return showFormSheet<Json>(
    context,
    builder: (_) => _RuleSheet(title: title, initial: rule == null ? ProgramDef.defaultRule('NONE') : deepCopy(rule), error: error),
  );
}

class _RuleSheet extends StatefulWidget {
  const _RuleSheet({required this.title, required this.initial, this.error});
  final String title;
  final Json initial;
  final String? error;

  @override
  State<_RuleSheet> createState() => _RuleSheetState();
}

class _RuleSheetState extends State<_RuleSheet> {
  late Json rule = widget.initial;

  String get type => rule['type'] is String ? rule['type'] as String : 'NONE';
  void _refresh() => setState(() {});

  void _setType(String t) {
    if (t == type) return;
    rule = ProgramDef.defaultRule(t);
    _refresh();
  }

  Json _sub(String k, Json Function() make) => (rule[k] ??= make()) as Json;

  List<Widget> _stagesForm() => [
    _RowsEditor(
      key: const Key('rule-stages'),
      title: ET.stages,
      rows: (rule['stages'] ??= <dynamic>[]) as List<dynamic>,
      makeRow: () => {'sets': 5, 'reps': 5},
      fields: const [(field: 'sets', label: ET.stageSets, scale: 1.0), (field: 'reps', label: ET.stageReps, scale: 1.0)],
      toggle: (field: 'lastAmrap', label: ET.stageLastAmrap),
      onChanged: _refresh,
    ),
  ];

  List<Widget> _tableForm() => [
    MapDropdown(
      key: const Key('rule-applyAt'),
      map: rule,
      field: 'applyAt',
      label: ET.applyAt,
      options: ET.applyAtTableNames,
      defaultValue: 'WEEK_END',
      onChanged: _refresh,
    ),
    _RowsEditor(
      key: const Key('rule-table'),
      title: ET.table,
      rows: (rule['table'] ??= <dynamic>[]) as List<dynamic>,
      makeRow: () => {'minReps': 0, 'incrementKg': 0},
      fields: const [
        (field: 'minReps', label: ET.minReps, scale: 1.0),
        (field: 'maxReps', label: ET.maxReps, scale: 1.0),
        (field: 'incrementKg', label: ET.amountKg, scale: 1.0),
      ],
      onChanged: _refresh,
    ),
  ];

  List<Widget> _customForm() {
    final success = _sub('success', () => <String, dynamic>{'when': 'ALL_SETS', 'method': 'ADD_KG', 'amount': 2.5});
    final hasFailure = rule['failure'] is Map;
    final failure = hasFailure ? rule['failure'] as Json : null;
    final when = success['when'] as String? ?? 'ALL_SETS';
    return [
      MapDropdown(
        key: const Key('rule-target'),
        map: rule,
        field: 'target',
        label: ET.target,
        options: ET.targetNames,
        defaultValue: 'WORKING',
        onChanged: _refresh,
      ),
      MapDropdown(
        key: const Key('rule-applyAt'),
        map: rule,
        field: 'applyAt',
        label: ET.applyAt,
        options: ET.applyAtNames,
        defaultValue: 'SESSION',
        onChanged: _refresh,
      ),
      Text(ET.success, style: Theme.of(context).textTheme.titleSmall),
      MapDropdown(
        key: const Key('rule-success-when'),
        map: success,
        field: 'when',
        label: ET.when,
        options: ET.successWhenNames,
        defaultValue: 'ALL_SETS',
        onChanged: () {
          if (success['when'] == 'AMRAP_REPS') {
            success['method'] = 'ADD_KG';
            rule['steps'] ??= <dynamic>[
              {'minReps': 1, 'amount': 2.5},
            ];
          }
          _refresh();
        },
      ),
      Row(
        children: [
          Expanded(
            child: MapNumField(
              key: const Key('rule-success-after'),
              map: success,
              field: 'afterConsecutive',
              label: ET.afterConsecutive,
              integer: true,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: MapDropdown(
              key: const Key('rule-success-method'),
              map: success,
              field: 'method',
              label: ET.method,
              options: when == 'AMRAP_REPS' ? {'ADD_KG': ET.successMethodNames['ADD_KG']!} : ET.successMethodNames,
              defaultValue: 'ADD_KG',
              onChanged: _refresh,
            ),
          ),
        ],
      ),
      if (when != 'AMRAP_REPS')
        MapNumField(
          key: const Key('rule-success-amount'),
          map: success,
          field: 'amount',
          label: ET.amount,
          helper: switch (success['method']) {
            'ADD_PERCENT' => '예: 0.025는 2.5%',
            'E1RM' => '0.5~1.0, 예: 0.9는 추정 1RM의 90%',
            _ => 'kg',
          },
        )
      else
        _RowsEditor(
          key: const Key('rule-steps'),
          title: ET.steps,
          rows: (rule['steps'] ??= <dynamic>[]) as List<dynamic>,
          makeRow: () => {'minReps': 1, 'amount': 2.5},
          fields: const [
            (field: 'minReps', label: ET.minReps, scale: 1.0),
            (field: 'maxReps', label: ET.maxReps, scale: 1.0),
            (field: 'amount', label: ET.amountKg, scale: 1.0),
          ],
          onChanged: _refresh,
        ),
      Text(ET.failure, style: Theme.of(context).textTheme.titleSmall),
      SwitchListTile(
        key: const Key('rule-failure-on'),
        contentPadding: EdgeInsets.zero,
        title: const Text(ET.failureOn),
        value: hasFailure,
        onChanged: (v) {
          if (v) {
            rule['failure'] = <String, dynamic>{'when': 'ANY_SET', 'afterConsecutive': 3, 'method': 'MULTIPLY', 'amount': 0.9};
          } else {
            rule.remove('failure');
          }
          _refresh();
        },
      ),
      if (failure != null) ...[
        MapDropdown(
          key: const Key('rule-failure-when'),
          map: failure,
          field: 'when',
          label: ET.when,
          options: ET.failureWhenNames,
          defaultValue: 'ANY_SET',
          onChanged: _refresh,
        ),
        Row(
          children: [
            Expanded(
              child: MapNumField(
                key: const Key('rule-failure-after'),
                map: failure,
                field: 'afterConsecutive',
                label: ET.afterConsecutive,
                integer: true,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: MapDropdown(
                key: const Key('rule-failure-method'),
                map: failure,
                field: 'method',
                label: ET.method,
                options: ET.failureMethodNames,
                defaultValue: 'MULTIPLY',
                onChanged: _refresh,
              ),
            ),
          ],
        ),
        if (failure['method'] != 'NONE')
          MapNumField(
            key: const Key('rule-failure-amount'),
            map: failure,
            field: 'amount',
            label: ET.amount,
            helper: failure['method'] == 'SUBTRACT_KG' ? 'kg' : '0.5~1.0, 예: 0.9는 90%로 낮춤',
          ),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = type;
    return FormSheet<Json>(
      title: widget.title,
      submitLabel: l.commonSave,
      onSubmit: () async => rule,
      children: [
        if (widget.error != null) Text(widget.error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        DropdownButtonFormField<String>(
          key: Key('rule-type-$t'),
          initialValue: t,
          isExpanded: true,
          decoration: const InputDecoration(isDense: true, labelText: ET.ruleType, border: OutlineInputBorder()),
          items: [for (final e in ET.ruleTypeNames.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
          onChanged: (v) {
            if (v != null) _setType(v);
          },
        ),
        if (t == 'LINEAR' || t == 'DOUBLE' || t == 'CYCLE' || t == 'STAGES')
          MapNumField(key: const Key('rule-incrementKg'), map: rule, field: 'incrementKg', label: ET.incrementKg),
        if (t == 'LINEAR' || t == 'DOUBLE' || t == 'AMRAP_TABLE')
          MapNumField(
            key: const Key('rule-failuresBeforeDeload'),
            map: rule,
            field: 'failuresBeforeDeload',
            label: ET.failuresBeforeDeload,
            integer: true,
          ),
        if (t != 'NONE' && t != 'CUSTOM')
          MapNumField(
            key: const Key('rule-deloadPercent'),
            map: rule,
            field: 'deloadPercent',
            label: ET.deloadPercent,
            scale: 100,
            suffix: '%',
          ),
        if (t == 'STAGES') ..._stagesForm(),
        if (t == 'AMRAP_TABLE') ..._tableForm(),
        if (t == 'CUSTOM') ..._customForm(),
      ],
    );
  }
}

typedef _RowField = ({String field, String label, double scale});

/// 같은 모양의 줄 목록(표·단계). 줄 추가·삭제.
class _RowsEditor extends StatelessWidget {
  const _RowsEditor({
    super.key,
    required this.title,
    required this.rows,
    required this.makeRow,
    required this.fields,
    required this.onChanged,
    this.toggle,
  });
  final String title;
  final List<dynamic> rows;
  final Json Function() makeRow;
  final List<_RowField> fields;
  final ({String field, String label})? toggle;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        for (var i = 0; i < rows.length; i++)
          Padding(
            key: ObjectKey(rows[i]),
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final f in fields) ...[
                  Expanded(
                    child: MapNumField(
                      key: Key('row$i-${f.field}'),
                      map: rows[i] as Json,
                      field: f.field,
                      label: f.label,
                      integer: f.field != 'incrementKg' && f.field != 'amount',
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                if (toggle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Column(
                      children: [
                        Text(toggle!.label, style: Theme.of(context).textTheme.labelSmall),
                        Switch(
                          key: Key('row$i-${toggle!.field}'),
                          value: (rows[i] as Json)[toggle!.field] == true,
                          onChanged: (v) {
                            final r = rows[i] as Json;
                            if (v) {
                              r[toggle!.field] = true;
                            } else {
                              r.remove(toggle!.field);
                            }
                            onChanged();
                          },
                        ),
                      ],
                    ),
                  ),
                IconButton(
                  key: Key('row$i-remove'),
                  tooltip: AppLocalizations.of(context).commonDelete,
                  onPressed: rows.length <= 1
                      ? null
                      : () {
                          rows.removeAt(i);
                          onChanged();
                        },
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            key: const Key('rows-add'),
            onPressed: () {
              rows.add(makeRow());
              onChanged();
            },
            icon: const Icon(Icons.add),
            label: const Text(ET.addRow),
          ),
        ),
      ],
    );
  }
}
