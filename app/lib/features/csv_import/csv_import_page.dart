// B3(v1.2) 다른 앱 기록 가져오기 화면(DAT-3). 형식·파일·무게 단위 → 미리보기 요약 → 확정(조각별 진행) → 결과.
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/csv_import_dto.dart';
import '../../core/api/dto.dart' show WeightUnit;
import '../../core/ui/bottom_action_bar.dart';
import '../../core/ui/unsaved_guard.dart';
import '../../l10n/gen/app_localizations.dart';
import 'csv_import_controller.dart';

typedef PickedCsv = ({String name, Uint8List bytes});

/// .csv 파일을 골라 이름과 바이트를 돌려준다(취소하면 null). 테스트에서 override 한다.
final csvFilePickerProvider = Provider<Future<PickedCsv?> Function()>((ref) {
  return () async {
    final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: const ['csv']);
    if (f == null) return null;
    return (name: f.name, bytes: await f.readAsBytes());
  };
});

class CsvImportPage extends ConsumerStatefulWidget {
  const CsvImportPage({super.key});

  @override
  ConsumerState<CsvImportPage> createState() => _CsvImportPageState();
}

class _CsvImportPageState extends ConsumerState<CsvImportPage> {
  String? _readError;

  Future<void> _pick() async {
    final l = AppLocalizations.of(context);
    final f = await ref.read(csvFilePickerProvider)();
    if (f == null || !mounted) return;
    if (f.bytes.length > csvMaxBytes) {
      setState(() => _readError = null);
      ref.read(csvImportControllerProvider.notifier).setFile(f.name, '', f.bytes.length);
      return;
    }
    try {
      var s = utf8.decode(f.bytes);
      if (s.startsWith('﻿')) s = s.substring(1);
      setState(() => _readError = null);
      ref.read(csvImportControllerProvider.notifier).setFile(f.name, s, f.bytes.length);
    } on FormatException {
      setState(() => _readError = l.csvFileReadError);
    }
  }

  String _errorText(AppLocalizations l, CsvError e) => switch (e.kind) {
    CsvErrorKind.tooLarge => l.csvErrTooLarge,
    CsvErrorKind.badFormat => e.detail == null ? l.csvErrBadFormat : '${l.csvErrBadFormat}\n${e.detail}',
    CsvErrorKind.network => l.csvErrNetwork,
    CsvErrorKind.conflict => l.csvErrConflict,
    CsvErrorKind.other => l.csvErrOther,
  };

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final s = ref.watch(csvImportControllerProvider);
    final c = ref.read(csvImportControllerProvider.notifier);
    final errorText = s.error == null ? _readError : _errorText(l, s.error!);

    final Widget body = switch (s.step) {
      CsvStep.input => _InputView(state: s, readError: errorText, onPick: _pick),
      CsvStep.working => _Working(label: l.csvWorking),
      CsvStep.preview || CsvStep.confirming => _PreviewView(state: s),
      CsvStep.done => _DoneView(state: s),
    };

    final Widget? bar = switch (s.step) {
      CsvStep.input => BottomActionBar(
        child: FilledButton(
          key: const Key('csv-preview'),
          onPressed: s.canPreview ? c.loadPreview : null,
          child: Text(l.csvPreviewAction),
        ),
      ),
      CsvStep.working => null,
      CsvStep.preview => BottomActionBar(
        error: errorText ?? (s.partiallySaved ? l.csvPartial(s.index, s.totalChunks) : null),
        child: Row(
          children: [
            OutlinedButton(key: const Key('csv-back'), onPressed: c.backToInput, child: Text(l.commonCancel)),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                key: const Key('csv-confirm'),
                onPressed: s.canConfirm ? c.confirm : null,
                child: Text(s.partiallySaved ? l.csvConfirmResume : l.csvConfirmAction),
              ),
            ),
          ],
        ),
      ),
      CsvStep.confirming => BottomActionBar(
        child: FilledButton(
          key: const Key('csv-confirm'),
          onPressed: null,
          child: Text(l.csvConfirming(s.index + 1, s.totalChunks)),
        ),
      ),
      CsvStep.done => BottomActionBar(
        child: FilledButton(key: const Key('csv-done'), onPressed: () => context.pop(), child: Text(l.csvDone)),
      ),
    };

    return UnsavedGuard(
      dirty: s.step == CsvStep.confirming,
      child: Scaffold(
        appBar: AppBar(title: Text(l.csvTitle)),
        body: body,
        bottomNavigationBar: bar,
      ),
    );
  }
}

class _Working extends StatelessWidget {
  const _Working({required this.label});
  final String label;
  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [const CircularProgressIndicator(), const SizedBox(height: 12), Text(label)],
    ),
  );
}

class _InputView extends ConsumerWidget {
  const _InputView({required this.state, required this.readError, required this.onPick});
  final CsvImportState state;
  final String? readError;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final c = ref.read(csvImportControllerProvider.notifier);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(l.csvIntro),
        const SizedBox(height: 16),
        Text(l.csvFormatLabel, style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        SegmentedButton<CsvFormat>(
          key: const Key('csv-format'),
          showSelectedIcon: false,
          segments: [
            ButtonSegment(value: CsvFormat.STRONG, label: Text(l.csvFormatStrong)),
            ButtonSegment(value: CsvFormat.HEVY, label: Text(l.csvFormatHevy)),
            ButtonSegment(value: CsvFormat.AUTO, label: Text(l.csvFormatAuto)),
          ],
          selected: {state.format},
          onSelectionChanged: (v) => c.setFormat(v.first),
        ),
        if (state.format == CsvFormat.STRONG) ...[
          const SizedBox(height: 16),
          Text(l.csvUnitLabel, style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          SegmentedButton<WeightUnit>(
            key: const Key('csv-unit'),
            showSelectedIcon: false,
            segments: [
              ButtonSegment(value: WeightUnit.KG, label: Text(l.settingsUnitKg)),
              ButtonSegment(value: WeightUnit.LB, label: Text(l.settingsUnitLb)),
            ],
            selected: {state.weightUnit},
            onSelectionChanged: (v) => c.setWeightUnit(v.first),
          ),
        ],
        const SizedBox(height: 16),
        if (state.hasFile)
          Card(
            child: ListTile(
              key: const Key('csv-file'),
              leading: const Icon(Icons.description_outlined),
              title: Text(l.csvFileLoaded(state.fileName ?? '', (state.csvText!.length / 1024).ceil())),
            ),
          ),
        OutlinedButton.icon(
          key: const Key('csv-pick'),
          onPressed: onPick,
          icon: const Icon(Icons.folder_open),
          label: Text(state.hasFile ? l.csvPickAnother : l.csvPickFile),
        ),
        if (readError != null) ...[
          const SizedBox(height: 12),
          Text(readError!, key: const Key('csv-error'), style: TextStyle(color: theme.colorScheme.error)),
        ],
      ],
    );
  }
}

class _PreviewView extends StatelessWidget {
  const _PreviewView({required this.state});
  final CsvImportState state;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final p = state.preview!;
    final csv = p.csv;
    final confirming = state.step == CsvStep.confirming;
    final formatName = switch (csv.format) {
      CsvFormat.STRONG => l.csvFormatStrong,
      CsvFormat.HEVY => l.csvFormatHevy,
      CsvFormat.AUTO => l.csvFormatAuto,
    };
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (confirming) ...[
          LinearProgressIndicator(key: const Key('csv-progress'), value: p.chunks.isEmpty ? null : state.index / p.chunks.length),
          const SizedBox(height: 16),
        ],
        Text(l.csvDetectedFormat(formatName), style: theme.textTheme.bodySmall),
        const SizedBox(height: 8),
        if (csv.sessions == 0)
          Text(l.csvNothing, key: const Key('csv-nothing'))
        else ...[
          Text(l.csvSummarySessions(csv.sessions), key: const Key('csv-sessions'), style: theme.textTheme.titleMedium),
          Text(l.csvSummarySets(csv.sets), key: const Key('csv-sets'), style: theme.textTheme.titleMedium),
          Text(l.csvSummaryMatched(csv.matchedExercises)),
        ],
        const SizedBox(height: 16),
        Text(
          csv.newExercises.isEmpty ? l.csvNoNewExercises : l.csvNewExercises(csv.newExercises.length),
          style: theme.textTheme.titleSmall,
        ),
        if (csv.newExercises.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            key: const Key('csv-new-exercises'),
            spacing: 8,
            runSpacing: 4,
            children: [for (final n in csv.newExercises) Chip(label: Text(n))],
          ),
        ],
        if (p.conflictCount > 0) ...[
          const SizedBox(height: 16),
          Text(l.csvConflicts(p.conflictCount), key: const Key('csv-conflicts')),
        ],
        if (csv.skippedRows.isNotEmpty) ...[
          const SizedBox(height: 8),
          ExpansionTile(
            key: const Key('csv-skipped'),
            tilePadding: EdgeInsets.zero,
            title: Text(l.csvSkippedRows(csv.skippedRows.length)),
            children: [
              for (final r in csv.skippedRows)
                ListTile(dense: true, contentPadding: EdgeInsets.zero, title: Text(l.csvSkippedLine(r.line, r.reason))),
            ],
          ),
        ],
      ],
    );
  }
}

class _DoneView extends ConsumerWidget {
  const _DoneView({required this.state});
  final CsvImportState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final saved = state.batches.fold<int>(0, (a, b) => a + (b.summary['sessions'] ?? 0));
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Icon(Icons.check_circle, size: 56, color: theme.colorScheme.primary),
        const SizedBox(height: 8),
        Text(l.csvDoneTitle, textAlign: TextAlign.center, style: theme.textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(
          saved > 0 ? l.csvDoneBody(saved) : l.csvDoneNothing,
          key: const Key('csv-result'),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        Center(
          child: TextButton(
            key: const Key('csv-again'),
            onPressed: ref.read(csvImportControllerProvider.notifier).reset,
            child: Text(l.csvAnotherFile),
          ),
        ),
      ],
    );
  }
}
