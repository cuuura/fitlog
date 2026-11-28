// 프로그램 편집기 본 화면(PRG-2). 기본 정보·날 목록·증량 규칙을 고치고 서버 검증 뒤 저장한다.
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/api_client.dart';
import '../../core/ids.dart';
import '../../core/routes.dart';
import '../../core/theme.dart';
import '../../core/ui/bottom_action_bar.dart';
import '../../core/ui/confirm.dart';
import '../../core/ui/form_sheet.dart';
import '../../core/ui/row_menu.dart';
import '../../core/ui/undo.dart';
import '../../core/ui/unsaved_guard.dart';
import '../../core/widgets/reorder.dart';
import '../../data/providers.dart';
import '../../l10n/gen/app_localizations.dart';
import '../programs/program_common.dart';
import '../programs/programs_providers.dart';
import 'day_editor_page.dart';
import 'editor_common.dart';
import 'editor_fields.dart';
import 'editor_sheets.dart';
import 'editor_text.dart';
import 'program_definition.dart';

enum EditorMode { create, edit, copy, instance }

const _basicPaths = ['/name', '/description', '/roundingKg', '/barKg', '/tmPercent', '/cycleWeeks'];

class ProgramEditorPage extends ConsumerStatefulWidget {
  const ProgramEditorPage({super.key, this.programId, this.copyFromProgramId, this.instanceId});

  /// 내 프로그램 고치기.
  final String? programId;

  /// 템플릿·다른 프로그램을 복사해서 새로 만들기.
  final String? copyFromProgramId;

  /// 이 진행 중 프로그램만 고치기.
  final String? instanceId;

  @override
  ConsumerState<ProgramEditorPage> createState() => _ProgramEditorPageState();
}

class _ProgramEditorPageState extends ConsumerState<ProgramEditorPage> {
  ProgramDef? _def;
  Object? _loadError;
  String _initial = '';
  Set<String> _keepUnused = {};
  EditorErrors _errors = EditorErrors.none;
  String? _saveError;
  bool _saving = false;
  bool _saved = false;
  late final LiftNames _names = LiftNames(ref.read(exerciseRepositoryProvider));

  EditorMode get _mode => widget.instanceId != null
      ? EditorMode.instance
      : widget.copyFromProgramId != null
      ? EditorMode.copy
      : widget.programId != null
      ? EditorMode.edit
      : EditorMode.create;

  bool get _dirty => _def != null && !_saved && _snapshot() != _initial;
  String _snapshot() => _def == null ? '' : deepCopy(_def!.json).toString();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loadError = null);
    try {
      final repo = ref.read(programRepositoryProvider);
      ProgramDef def;
      switch (_mode) {
        case EditorMode.create:
          def = ProgramDef.blank();
        case EditorMode.edit:
          def = ProgramDef((await repo.getProgram(widget.programId!)).definition.cast<String, dynamic>());
        case EditorMode.copy:
          final p = await repo.getProgram(widget.copyFromProgramId!);
          def = ProgramDef(p.definition.cast<String, dynamic>());
          def.json.remove('family');
          def.json.remove('variantLabel');
          final base = '${def.json['name'] ?? p.name}';
          final room = 80 - ET.copySuffix.length;
          def.json['name'] = '${base.length > room ? base.substring(0, room) : base}${ET.copySuffix}';
        case EditorMode.instance:
          final inst = await repo.getInstance(widget.instanceId!);
          final raw = inst.definition ?? (await repo.getProgram(inst.programId)).definition;
          def = ProgramDef(raw.cast<String, dynamic>());
      }
      await _names.loadFor(def);
      if (!mounted) return;
      setState(() {
        _def = def;
        _keepUnused = def.unusedLiftKeys();
        // 복사·새로 만들기는 처음 상태가 "저장 전"이라 그대로 나가도 묻지 않는다.
        _initial = _snapshot();
      });
    } catch (e) {
      if (mounted) setState(() => _loadError = e);
    }
  }

  void _changed() => setState(() {});

  // ---------------------------------------------------------------- 저장

  Future<void> _save() async {
    final def = _def!;
    final l = AppLocalizations.of(context);
    final repo = ref.read(programRepositoryProvider);
    final out = def.toJson(keepUnused: _keepUnused).cast<String, Object?>();
    setState(() {
      _saving = true;
      _saveError = null;
      _errors = EditorErrors.none;
    });
    try {
      try {
        await repo.validateProgram(out);
      } on ApiException catch (e) {
        if (e.code == 'VALIDATION_FAILED') {
          if (!mounted) return;
          setState(() {
            _saving = false;
            _errors = EditorErrors(e.details.isEmpty ? [(path: '', message: e.message)] : e.details);
            _saveError = ET.fixErrors;
          });
          return;
        }
        rethrow;
      }
      switch (_mode) {
        case EditorMode.instance:
          final r = await _replaceWithPrompt(widget.instanceId!, out);
          if (!mounted) return;
          if (r != null) {
            setState(() {
              _saving = false;
              _saveError = r;
            });
            return;
          }
          ref.invalidate(instanceViewProvider);
          ref.invalidate(instanceListProvider);
        case EditorMode.create:
        case EditorMode.copy:
          await repo.createProgram(newId(), out);
          ref.invalidate(programListProvider);
        case EditorMode.edit:
          final p = await repo.updateProgram(widget.programId!, name: out['name'] as String?, definition: out);
          ref.invalidate(programListProvider);
          ref.invalidate(programViewProvider);
          if (p.activeInstanceIds.isNotEmpty && mounted) {
            await _applyToInstances(p.activeInstanceIds, out);
          }
      }
      if (!mounted) return;
      _saved = true;
      if (context.canPop()) {
        context.pop(true);
      } else {
        context.go(Routes.programs);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _saveError = errorMessage(l, e, fallback: ET.saveFailed);
      });
    }
  }

  /// 진행 중인 인스턴스에도 적용할지 묻고 적용한다. 실패한 것은 메시지로 알린다.
  Future<void> _applyToInstances(List<String> ids, Map<String, Object?> def) async {
    final ok = await confirmAction(
      context,
      title: ET.applyConfirmTitle(ids.length),
      body: ET.applyConfirmBody,
      action: ET.applyConfirm,
    );
    if (!ok || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final failures = <String>[];
    for (final id in ids) {
      final r = await _replaceWithPrompt(id, def);
      if (r != null) failures.add(r);
      if (!mounted) return;
    }
    ref.invalidate(instanceViewProvider);
    ref.invalidate(instanceListProvider);
    messenger.showSnackBar(SnackBar(content: Text(failures.isEmpty ? ET.applyDone : '${ET.applyPartial}\n${failures.toSet().join('\n')}')));
  }

  /// 인스턴스 정의 교체. 빠진 시작 무게가 있으면 값을 물어 다시 보낸다. 성공이면 null, 실패면 보여 줄 문구.
  Future<String?> _replaceWithPrompt(String instanceId, Map<String, Object?> def) async {
    final repo = ref.read(programRepositoryProvider);
    try {
      await repo.replaceInstanceDefinition(instanceId, def);
      return null;
    } on ApiException catch (e) {
      final missing = [
        for (final d in e.details)
          if (d.path.startsWith('/tm/') || d.path.startsWith('/working/')) d.path,
      ];
      if (e.code == 'VALIDATION_FAILED' && missing.isNotEmpty && mounted) {
        final done = await showFormSheet<bool>(
          context,
          builder: (_) => _MissingInputsSheet(
            paths: missing,
            labelOf: (key) => _names.labelFor(_def!, key),
            send: (tm, working) => repo.replaceInstanceDefinition(instanceId, def, tm: tm, working: working),
          ),
        );
        return done == true ? null : ET.missingTitle;
      }
      return e.message.isEmpty ? ET.saveFailed : e.message;
    }
  }

  // ---------------------------------------------------------------- 화면

  String? _err(String path) => _errors.textAt(path);

  Future<void> _addDay() async {
    final def = _def!;
    def.addDay('${def.days.length + 1}일차');
    _changed();
  }

  void _removeDay(int i) {
    final def = _def!;
    final removed = def.days.removeAt(i);
    _changed();
    showUndoSnack(
      ScaffoldMessenger.of(context),
      AppLocalizations.of(context),
      message: ET.dayDeleted,
      onUndo: () async {
        def.days.insert(i.clamp(0, def.days.length), removed);
        if (mounted) _changed();
      },
    );
  }

  Future<void> _openDay(int i) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DayEditorPage(
          def: _def!,
          dayIndex: i,
          names: _names,
          errors: _errors,
          onChanged: _changed,
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _editRule(String key) async {
    final def = _def!;
    final r = await showRuleSheet(
      context,
      title: _names.labelFor(def, key),
      rule: def.progression[key] as Json?,
    );
    if (r == null) return;
    if (r['type'] == 'NONE') {
      def.progression.remove(key);
    } else {
      def.progression[key] = r;
    }
    _changed();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final title = switch (_mode) {
      EditorMode.create => ET.titleNew,
      EditorMode.edit => ET.titleEdit,
      EditorMode.copy => ET.titleCopy,
      EditorMode.instance => ET.titleInstance,
    };
    final def = _def;
    return UnsavedGuard(
      dirty: _dirty,
      child: Scaffold(
        appBar: AppBar(title: Text(title)),
        body: def == null
            ? (_loadError == null
                  ? const Center(child: CircularProgressIndicator())
                  : ErrorRetry(error: _loadError!, onRetry: _load))
            : _body(context, def),
        bottomNavigationBar: def == null
            ? null
            : BottomActionBar(
                error: _saveError,
                child: FilledButton(
                  key: const Key('editor-save'),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(l.commonSave),
                ),
              ),
      ),
    );
  }

  Widget _body(BuildContext context, ProgramDef def) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final liftKeys = [
      for (final k in def.lifts.keys)
        if (def.usageCount(k) > 0) k,
    ];
    final unclaimed = _errors.unclaimed(_basicPaths, [
      '/days',
      for (final k in def.lifts.keys) '/progression/$k',
    ]);
    // /days 아래 에러는 날 카드·날 화면이 보여 준다. 날 카드 밖(예: /days 자체)은 맨 위에도 모은다.
    final topErrors = [
      for (final e in unclaimed) e.message,
      ..._errors.at('/days'),
    ];
    final roundings = {for (final v in ['0.5', '1', '1.25', '2.5', '5']) v: '$v kg'};
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_mode == EditorMode.instance)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(ET.instanceNote, key: const Key('editor-instance-note'), style: TextStyle(color: c.fg2)),
          ),
        if (topErrors.isNotEmpty)
          Card(
            key: const Key('editor-errors'),
            color: theme.colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [for (final m in topErrors) Text(m, style: TextStyle(color: theme.colorScheme.onErrorContainer))],
              ),
            ),
          ),
        Text(ET.basicInfo, style: theme.textTheme.titleMedium),
        const SizedBox(height: 12),
        MapTextField(
          key: const Key('editor-name'),
          map: def.json,
          field: 'name',
          label: ET.name,
          maxLength: 80,
          errorText: _err('/name'),
          onChanged: _changed,
        ),
        MapTextField(
          key: const Key('editor-description'),
          map: def.json,
          field: 'description',
          label: ET.description,
          maxLength: 2000,
          maxLines: null,
          errorText: _err('/description'),
          onChanged: _changed,
        ),
        const SizedBox(height: 8),
        _RoundingField(
          map: def.json,
          options: roundings,
          errorText: _err('/roundingKg'),
          onChanged: _changed,
        ),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: MapNumField(
                key: const Key('editor-barKg'),
                map: def.json,
                field: 'barKg',
                label: ET.barKg,
                suffix: 'kg',
                errorText: _err('/barKg'),
                onChanged: _changed,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: MapNumField(
                key: const Key('editor-tmPercent'),
                map: def.json,
                field: 'tmPercent',
                label: ET.tmPercent,
                scale: 100,
                suffix: '%',
                errorText: _err('/tmPercent'),
                onChanged: _changed,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        MapNumField(
          key: const Key('editor-cycleWeeks'),
          map: def.json,
          field: 'cycleWeeks',
          label: ET.cycleWeeks,
          helper: ET.cycleWeeksHelp,
          integer: true,
          errorText: _err('/cycleWeeks'),
          onChanged: _changed,
        ),
        const SizedBox(height: 24),
        Text(ET.days, style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        ReorderableListView(
          key: const Key('editor-days'),
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          onReorderStart: (_) => reorderHaptic(),
          onReorderItem: (from, to) {
            def.moveDay(from, to);
            _changed();
          },
          proxyDecorator: reorderProxy(),
          children: [
            for (var i = 0; i < def.days.length; i++) _dayCard(context, def, i),
          ],
        ),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            key: const Key('editor-add-day'),
            onPressed: def.days.length >= 14 ? null : _addDay,
            icon: const Icon(Icons.add),
            label: const Text(ET.addDay),
          ),
        ),
        const SizedBox(height: 16),
        Text(ET.rules, style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(ET.rulesHelp, style: theme.textTheme.bodySmall?.copyWith(color: c.fg2)),
        const SizedBox(height: 8),
        if (liftKeys.isEmpty) Text(ET.noLifts, style: TextStyle(color: c.fg2)),
        for (final k in liftKeys) _ruleTile(context, def, k),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _dayCard(BuildContext context, ProgramDef def, int i) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    final day = def.day(i);
    final errs = _errors.under('/days/$i');
    final wd = day['weekday'] as String?;
    return Card(
      key: ObjectKey(day),
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: InkWell(
        key: Key('day-card-$i'),
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: () => _openDay(i),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 0, 4),
          child: Row(
            children: [
              ReorderableDragStartListener(
                index: i,
                child: Padding(
                  key: Key('day-handle-$i'),
                  padding: const EdgeInsets.only(right: 8, top: 12, bottom: 12),
                  child: const Icon(Icons.drag_handle),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${day['name'] ?? ''}', style: theme.textTheme.titleSmall),
                      Text(
                        [if (wd != null) ET.weekdayName(wd), ET.dayLine(def.exercises(i).length)].join(' · '),
                        style: theme.textTheme.bodySmall?.copyWith(color: c.fg2),
                      ),
                      if (errs.isNotEmpty) Text(errs.join('\n'), style: theme.textTheme.bodySmall?.copyWith(color: c.fail)),
                    ],
                  ),
                ),
              ),
              RowMenu<String>(
                key: Key('day-menu-$i'),
                items: [
                  RowMenuItem(
                    value: 'delete',
                    label: ET.dayDelete,
                    destructive: true,
                    enabled: def.days.length > 1,
                    key: Key('day-delete-$i'),
                  ),
                ],
                onSelected: (_) => _removeDay(i),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _ruleTile(BuildContext context, ProgramDef def, String key) {
    final c = AppColors.of(context);
    final rule = def.progression[key];
    final errs = _errors.under('/progression/$key');
    return ListTile(
      key: Key('rule-$key'),
      contentPadding: EdgeInsets.zero,
      title: Text(_names.labelFor(def, key)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(rule is Map ? ET.ruleSummary(rule.cast<String, dynamic>()) : ET.ruleTypeNames['NONE']!),
          if (errs.isNotEmpty) Text(errs.join('\n'), style: TextStyle(color: c.fail)),
        ],
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _editRule(key),
    );
  }
}

/// 반올림 단위 고르기(0.5 / 1 / 1.25 / 2.5 / 5).
class _RoundingField extends StatelessWidget {
  const _RoundingField({required this.map, required this.options, this.errorText, required this.onChanged});
  final Json map;
  final Map<String, String> options;
  final String? errorText;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final v = map['roundingKg'];
    final cur = v is num ? fmtNum(v) : '2.5';
    return DropdownButtonFormField<String>(
      key: Key('editor-rounding-$cur'),
      initialValue: options.containsKey(cur) ? cur : null,
      isExpanded: true,
      decoration: InputDecoration(
        isDense: true,
        labelText: ET.rounding,
        errorText: errorText,
        border: const OutlineInputBorder(),
      ),
      items: [for (final e in options.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
      onChanged: (s) {
        if (s == null) return;
        map['roundingKg'] = double.parse(s);
        onChanged();
      },
    );
  }
}

/// 진행 중 프로그램에 적용할 때 빠진 시작 무게를 받는 시트. 보내기까지 이 안에서 한다.
class _MissingInputsSheet extends StatefulWidget {
  const _MissingInputsSheet({required this.paths, required this.labelOf, required this.send});
  final List<String> paths;
  final String Function(String key) labelOf;
  final Future<void> Function(Map<String, double> tm, Map<String, double> working) send;

  @override
  State<_MissingInputsSheet> createState() => _MissingInputsSheetState();
}

class _MissingInputsSheetState extends State<_MissingInputsSheet> {
  late final Map<String, TextEditingController> _c = {for (final p in widget.paths) p: TextEditingController()};
  bool _invalid = false;

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return FormSheet<bool>(
      title: ET.missingTitle,
      submitLabel: l.commonSave,
      failureMessage: (e) => e is ApiException && e.message.isNotEmpty ? e.message : l.commonError,
      onSubmit: () async {
        final tm = <String, double>{};
        final working = <String, double>{};
        var bad = false;
        for (final e in _c.entries) {
          final v = double.tryParse(e.value.text.trim().replaceAll(',', '.'));
          if (v == null || v < 0) {
            bad = true;
            continue;
          }
          if (e.key.startsWith('/tm/')) {
            tm[e.key.substring(4)] = v;
          } else {
            working[e.key.substring(9)] = v;
          }
        }
        if (bad) {
          setState(() => _invalid = true);
          return null;
        }
        await widget.send(tm, working);
        return true;
      },
      children: [
        const Text(ET.missingBody),
        for (final p in widget.paths)
          TextField(
            key: Key('missing-$p'),
            controller: _c[p],
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
            decoration: InputDecoration(
              isDense: true,
              labelText: '${widget.labelOf(p.startsWith('/tm/') ? p.substring(4) : p.substring(9))} · '
                  '${p.startsWith('/tm/') ? ET.missingTm : ET.missingWorking}',
              errorText: _invalid && double.tryParse(_c[p]!.text.trim().replaceAll(',', '.')) == null ? ET.missingInvalid : null,
              border: const OutlineInputBorder(),
            ),
          ),
      ],
    );
  }
}
