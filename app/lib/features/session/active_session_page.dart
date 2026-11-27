// ignore_for_file: curly_braces_in_flow_control_structures
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/dto.dart';
import '../../core/clock.dart';
import '../../core/settings/settings_controller.dart';
import '../../core/routes.dart';
import '../../l10n/gen/app_localizations.dart';
import '../exercise_picker/exercise_labels.dart';
import '../rest_timer/session_wakelock.dart';
import 'current_set.dart';
import 'plan_logic.dart';
import 'session_controller.dart';
import 'session_dock.dart';
import 'session_format.dart';
import 'set_row.dart';
import 'set_table.dart';

Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  String? body,
  required String confirmLabel,
  Key? confirmKey,
}) async {
  final l = AppLocalizations.of(context);
  final r = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: body == null ? null : Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c, false),
          child: Text(l.commonCancel),
        ),
        FilledButton(
          key: confirmKey ?? const Key('confirm-ok'),
          onPressed: () => Navigator.pop(c, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return r ?? false;
}

class ActiveSessionPage extends ConsumerStatefulWidget {
  const ActiveSessionPage({super.key});

  @override
  ConsumerState<ActiveSessionPage> createState() => _ActiveSessionPageState();
}

class _ActiveSessionPageState extends ConsumerState<ActiveSessionPage> {
  bool _leaving = false;

  /// 사용자가 직접 펼친 세트(현재 세트가 바뀌면 무효가 되어 다시 현재 세트를 따라간다).
  String? _pinId;
  String? _pinForCurrentId;

  Future<void> _addExercise(Session session) async {
    final id = await context.push<String>(Routes.pickExercise);
    if (id == null || !mounted) return;
    await ref
        .read(sessionControllerProvider)
        .addExercise(
          session.id,
          id,
          accessory: session.isProgram,
          firstSet: !session.isProgram,
        );
  }

  Future<void> _end(Session session) async {
    final l = AppLocalizations.of(context);
    final unfinished = [
      for (final e in session.exercises)
        for (final w in e.sets)
          if (isJudged(e, w) && !w.isCompleted) w,
    ].length;
    final ok = await confirmDialog(
      context,
      title: l.sessionEndConfirmTitle,
      body: unfinished == 0
          ? l.sessionEndConfirmBody
          : '${l.sessionEndConfirmBody}\n${l.sessionEndUnfinishedWarning(unfinished)}',
      confirmLabel: l.sessionEnd,
      confirmKey: const Key('end-confirm'),
    );
    if (!ok || !mounted) return;
    _leaving = true;
    await ref.read(sessionControllerProvider).end(session.id);
    if (mounted) context.go(Routes.sessionSummary(session.id));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final async = ref.watch(activeSessionProvider);
    final session = async.value;
    final exercises =
        ref.watch(exerciseMapProvider).value ?? const <String, Exercise>{};

    if (async.hasValue && session == null) {
      if (!_leaving) {
        _leaving = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) context.go(Routes.home);
        });
      }
      return const Scaffold(body: SizedBox.shrink());
    }
    if (session == null)
      return const Scaffold(body: Center(child: CircularProgressIndicator()));

    final largeText = MediaQuery.textScalerOf(context).scale(10) > 13;
    final currentId = currentSetOf(session)?.set.id;
    final pinned =
        _pinId != null &&
            _pinForCurrentId == currentId &&
            session.exercises.any((e) => e.sets.any((w) => w.id == _pinId))
        ? _pinId
        : null;
    final expandedId = pinned ?? currentId;
    return SessionWakelock(
      child: Scaffold(
        appBar: AppBar(
          // 큰 글씨에서는 제목 자리에 경과 시간만 두고, 종료 버튼은 줄여서 앱바 폭을 넘지 않게 한다.
          title: largeText
              ? _Elapsed(startedAt: session.startedAt)
              : Text(l.sessionTitle),
          actions: [
            if (!largeText) ...[
              Center(child: _Elapsed(startedAt: session.startedAt)),
              const SizedBox(width: 8),
            ],
            TextButton(
              key: const Key('end-session'),
              onPressed: () => _end(session),
              child: largeText
                  ? ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 140),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(l.sessionEnd),
                      ),
                    )
                  : Text(l.sessionEnd),
            ),
          ],
        ),
        bottomNavigationBar: SessionDock(
          session: session,
          exercises: exercises,
        ),
        body: ReorderableListView.builder(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
          buildDefaultDragHandles: false,
          header: Column(
            children: [
              if (session.isProgram) _PlanHeader(session: session),
              NoteField(
                key: ValueKey('session-note-${session.id}'),
                fieldKey: const Key('session-note'),
                label: l.sessionNoteHint,
                value: session.note,
                onSave: (v) => ref
                    .read(sessionControllerProvider)
                    .setSessionNote(session.id, v),
              ),
              const SizedBox(height: 8),
              if (session.exercises.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(32),
                  child: Center(child: Text(l.sessionEmptyExercises)),
                ),
            ],
          ),
          footer: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: OutlinedButton.icon(
              key: const Key('add-exercise'),
              icon: const Icon(Icons.add),
              label: Text(l.sessionAddExercise),
              onPressed: () => _addExercise(session),
            ),
          ),
          itemCount: session.exercises.length,
          onReorderItem: (o, n) {
            final ids = [for (final e in session.exercises) e.id];
            ids.insert(n, ids.removeAt(o));
            ref
                .read(sessionControllerProvider)
                .reorderExercises(session.id, ids);
          },
          itemBuilder: (context, i) {
            final se = session.exercises[i];
            return _ExerciseCard(
              key: ValueKey(se.id),
              session: session,
              se: se,
              index: i,
              exercise: exercises[se.exerciseId],
              expandedSetId: expandedId,
              currentSetId: currentId,
              onSelect: (id) => setState(() {
                _pinId = id;
                _pinForCurrentId = currentId;
              }),
            );
          },
        ),
      ),
    );
  }
}

/// 프로그램 이름·회차(dayName, 주차).
class _PlanHeader extends ConsumerWidget {
  const _PlanHeader({required this.session});
  final Session session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final label = ref.watch(planLabelsProvider)[session.id];
    final inst = ref
        .watch(planItemsProvider)
        .value
        ?.where((p) => p.instance.id == session.programInstanceId)
        .firstOrNull
        ?.instance;
    final name = (label?.programName.isNotEmpty ?? false)
        ? label!.programName
        : inst?.name;
    final day = label?.dayName ?? session.planDayKey ?? '';
    final week = label?.week ?? inst?.state.week ?? 1;
    final text = name == null
        ? l.sessionPlanHeaderNoName(day, week)
        : l.sessionPlanHeader(name, day, week);
    return Card(
      key: const Key('plan-header'),
      color: Theme.of(context).colorScheme.primaryContainer,
      child: ListTile(
        dense: true,
        leading: const Icon(Icons.event_note_outlined),
        title: Text(text),
      ),
    );
  }
}

class _Elapsed extends ConsumerStatefulWidget {
  const _Elapsed({required this.startedAt});
  final DateTime startedAt;
  @override
  ConsumerState<_Elapsed> createState() => _ElapsedState();
}

class _ElapsedState extends ConsumerState<_Elapsed> {
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = ref.read(clockProvider)().difference(widget.startedAt);
    return Text(
      key: const Key('elapsed'),
      formatElapsed(d.isNegative ? Duration.zero : d),
    );
  }
}

/// 포커스를 잃거나 제출하면 저장하는 메모 입력.
class NoteField extends StatefulWidget {
  const NoteField({
    super.key,
    required this.fieldKey,
    required this.label,
    required this.value,
    required this.onSave,
  });
  final Key fieldKey;
  final String label;
  final String? value;
  final void Function(String?) onSave;

  @override
  State<NoteField> createState() => _NoteFieldState();
}

class _NoteFieldState extends State<NoteField> {
  late final _c = TextEditingController(text: widget.value ?? '');
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _save();
    });
  }

  void _save() {
    final t = _c.text.trim();
    if (t != (widget.value ?? '')) widget.onSave(t.isEmpty ? null : t);
  }

  @override
  void dispose() {
    _focus.dispose();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    key: widget.fieldKey,
    controller: _c,
    focusNode: _focus,
    onSubmitted: (_) => _save(),
    onTapOutside: (_) => _focus.unfocus(),
    decoration: InputDecoration(
      isDense: true,
      labelText: widget.label,
      border: const OutlineInputBorder(),
    ),
  );
}

class _ExerciseCard extends ConsumerWidget {
  const _ExerciseCard({
    super.key,
    required this.session,
    required this.se,
    required this.index,
    required this.exercise,
    required this.expandedSetId,
    required this.currentSetId,
    required this.onSelect,
  });
  final String? expandedSetId;
  final String? currentSetId;
  final void Function(String setId) onSelect;
  final Session session;
  final int index;
  final SessionExercise se;
  final Exercise? exercise;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final ctrl = ref.read(sessionControllerProvider);
    final type = exercise?.type ?? ExerciseType.BARBELL;
    final name = exercise == null
        ? '…'
        : exerciseDisplayName(context, exercise!);
    final last = ref
        .watch(
          lastSetsProvider((exerciseId: se.exerciseId, sessionId: session.id)),
        )
        .value;
    final unit = ref.watch(settingsProvider).weightUnit;
    final pastDay = session.isProgram && session.planDayKey != null
        ? ref
              .watch(
                lastDaySessionProvider((
                  instanceId: session.programInstanceId!,
                  dayKey: session.planDayKey!,
                  sessionId: session.id,
                )),
              )
              .value
        : null;
    final pastSe = pastDay?.exercises
        .where(
          (e) => se.liftKey != null
              ? e.liftKey == se.liftKey
              : e.exerciseId == se.exerciseId,
        )
        .firstOrNull;
    final progress = exerciseProgress(se);
    final pastText = pastSe == null
        ? ''
        : formatPastSets(pastSe.sets, type, unit);

    return Card(
      key: Key('exercise-${se.id}'),
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 12, right: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                name,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ),
                            if (se.accessory) ...[
                              const SizedBox(width: 8),
                              Chip(
                                key: Key('accessory-${se.id}'),
                                label: Text(l.sessionAccessoryBadge),
                                visualDensity: VisualDensity.compact,
                              ),
                            ],
                          ],
                        ),
                        Wrap(
                          spacing: 8,
                          children: [
                            Text(
                              typeLabel(l, type),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            if (progress.total > 0)
                              Text(
                                l.sessionTableProgress(
                                  progress.done,
                                  progress.total,
                                ),
                                key: Key('progress-${se.id}'),
                                style: Theme.of(context).textTheme.labelLarge
                                    ?.copyWith(
                                      color: progress.done == progress.total
                                          ? Theme.of(context)
                                                .colorScheme
                                                .primary
                                          : null,
                                    ),
                              ),
                          ],
                        ),
                        if (pastText.isNotEmpty)
                          Text(
                            l.sessionLastDay(pastText),
                            key: Key('past-day-${se.id}'),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                      ],
                    ),
                  ),
                  ReorderableDragStartListener(
                    index: index,
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Icon(
                        Icons.drag_handle,
                        key: Key('drag-exercise-${se.id}'),
                      ),
                    ),
                  ),
                  IconButton(
                    key: Key('remove-exercise-${se.id}'),
                    tooltip: l.sessionRemoveExercise,
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      final ok = await confirmDialog(
                        context,
                        title: l.sessionRemoveExercise,
                        body: l.sessionRemoveExerciseConfirm(name),
                        confirmLabel: l.commonDelete,
                        confirmKey: const Key('remove-exercise-confirm'),
                      );
                      if (ok) await ctrl.removeExercise(se.id);
                    },
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
              child: NoteField(
                key: ValueKey('note-${se.id}'),
                fieldKey: Key('exercise-note-${se.id}'),
                label: l.sessionExerciseNoteHint,
                value: se.note,
                onSave: (v) => ctrl.setExerciseNote(se.id, v),
              ),
            ),
            if (se.sets.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                child: Text(
                  l.sessionTableEmptyHint,
                  key: Key('empty-sets-${se.id}'),
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              )
            else
              SetTableHeader(type: type),
            ReorderableListView.builder(
              key: Key('sets-${se.id}'),
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              itemCount: se.sets.length,
              onReorderItem: (o, n) {
                final ids = [for (final w in se.sets) w.id];
                ids.insert(n, ids.removeAt(o));
                ctrl.reorderSets(se.id, ids);
              },
              itemBuilder: (context, i) => SetRow(
                key: ValueKey(se.sets[i].id),
                session: session,
                sessionExercise: se,
                exerciseName: name,
                type: type,
                set: se.sets[i],
                index: i,
                label: setShortLabel(l, se, se.sets[i]),
                expanded: se.sets[i].id == expandedSetId,
                isCurrent: se.sets[i].id == currentSetId,
                onSelect: () => onSelect(se.sets[i].id),
                previous: last == null || last.sets.isEmpty
                    ? null
                    : (i < last.sets.length ? last.sets[i] : last.sets.last),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: se.sets.isEmpty
                  ? FilledButton.tonalIcon(
                      key: Key('add-set-${se.id}'),
                      icon: const Icon(Icons.add),
                      label: Text(l.sessionAddSet),
                      onPressed: () => ctrl.addSet(session, se),
                    )
                  : TextButton.icon(
                      key: Key('add-set-${se.id}'),
                      icon: const Icon(Icons.add),
                      label: Text(l.sessionAddSet),
                      onPressed: () => ctrl.addSet(session, se),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
