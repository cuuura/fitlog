import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/dto.dart';
import '../../core/clock.dart';
import '../../core/routes.dart';
import '../../l10n/gen/app_localizations.dart';
import '../exercise_picker/exercise_labels.dart';
import '../rest_timer/rest_timer_bar.dart';
import '../rest_timer/session_wakelock.dart';
import 'session_controller.dart';
import 'session_format.dart';
import 'set_row.dart';

Future<bool> confirmDialog(BuildContext context,
    {required String title, String? body, required String confirmLabel, Key? confirmKey}) async {
  final l = AppLocalizations.of(context);
  final r = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: body == null ? null : Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: Text(l.commonCancel)),
        FilledButton(key: confirmKey ?? const Key('confirm-ok'), onPressed: () => Navigator.pop(c, true), child: Text(confirmLabel)),
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

  Future<void> _addExercise(Session session) async {
    final id = await context.push<String>(Routes.pickExercise);
    if (id == null || !mounted) return;
    await ref.read(sessionControllerProvider).addExercise(session.id, id);
  }

  Future<void> _end(Session session) async {
    final l = AppLocalizations.of(context);
    final ok = await confirmDialog(context,
        title: l.sessionEndConfirmTitle, body: l.sessionEndConfirmBody, confirmLabel: l.sessionEnd, confirmKey: const Key('end-confirm'));
    if (!ok || !mounted) return;
    _leaving = true;
    await ref.read(sessionControllerProvider).end(session.id);
    if (mounted) context.go(Routes.home);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final async = ref.watch(activeSessionProvider);
    final session = async.value;
    final exercises = ref.watch(exerciseMapProvider).value ?? const <String, Exercise>{};

    if (async.hasValue && session == null) {
      if (!_leaving) {
        _leaving = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) context.go(Routes.home);
        });
      }
      return const Scaffold(body: SizedBox.shrink());
    }
    if (session == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));

    return SessionWakelock(
      child: Scaffold(
        appBar: AppBar(
          title: Text(l.sessionTitle),
          actions: [
            Center(child: _Elapsed(startedAt: session.startedAt)),
            const SizedBox(width: 8),
            TextButton(key: const Key('end-session'), onPressed: () => _end(session), child: Text(l.sessionEnd)),
          ],
        ),
        bottomNavigationBar: const SafeArea(child: RestTimerBar()),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
          children: [
            NoteField(
              key: ValueKey('session-note-${session.id}'),
              fieldKey: const Key('session-note'),
              label: l.sessionNoteHint,
              value: session.note,
              onSave: (v) => ref.read(sessionControllerProvider).setSessionNote(session.id, v),
            ),
            const SizedBox(height: 8),
            if (session.exercises.isEmpty)
              Padding(padding: const EdgeInsets.all(32), child: Center(child: Text(l.sessionEmptyExercises))),
            for (final se in session.exercises)
              _ExerciseCard(key: ValueKey(se.id), session: session, se: se, exercise: exercises[se.exerciseId]),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const Key('add-exercise'),
              icon: const Icon(Icons.add),
              label: Text(l.sessionAddExercise),
              onPressed: () => _addExercise(session),
            ),
          ],
        ),
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
    return Text(key: const Key('elapsed'), formatElapsed(d.isNegative ? Duration.zero : d));
  }
}

/// 포커스를 잃거나 제출하면 저장하는 메모 입력.
class NoteField extends StatefulWidget {
  const NoteField({super.key, required this.fieldKey, required this.label, required this.value, required this.onSave});
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
        decoration: InputDecoration(isDense: true, labelText: widget.label, border: const OutlineInputBorder()),
      );
}

class _ExerciseCard extends ConsumerWidget {
  const _ExerciseCard({super.key, required this.session, required this.se, required this.exercise});
  final Session session;
  final SessionExercise se;
  final Exercise? exercise;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final ctrl = ref.read(sessionControllerProvider);
    final type = exercise?.type ?? ExerciseType.BARBELL;
    final name = exercise == null ? '…' : exerciseDisplayName(context, exercise!);
    final last = ref.watch(lastSetsProvider((exerciseId: se.exerciseId, sessionId: session.id))).value;

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
                        Text(name, style: Theme.of(context).textTheme.titleMedium),
                        Text(typeLabel(l, type), style: Theme.of(context).textTheme.bodySmall),
                      ],
                    ),
                  ),
                  IconButton(
                    key: Key('remove-exercise-${se.id}'),
                    tooltip: l.sessionRemoveExercise,
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      final ok = await confirmDialog(context,
                          title: l.sessionRemoveExercise,
                          body: l.sessionRemoveExerciseConfirm(name),
                          confirmLabel: l.commonDelete,
                          confirmKey: const Key('remove-exercise-confirm'));
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
            for (var i = 0; i < se.sets.length; i++)
              SetRow(
                key: ValueKey(se.sets[i].id),
                session: session,
                sessionExercise: se,
                exerciseName: name,
                type: type,
                set: se.sets[i],
                index: i,
                previous: last == null || last.sets.isEmpty ? null : (i < last.sets.length ? last.sets[i] : last.sets.last),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: TextButton.icon(
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
