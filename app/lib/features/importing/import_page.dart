// B1 소유. JSON 가져오기: 입력 → 미리보기·충돌 해결 → 결과. 진입 경로는 Routes.importJson.
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/ai_dto.dart';
import '../../core/api/dto.dart';
import '../../core/clock.dart';
import '../../core/routes.dart';
import '../../core/settings/settings_controller.dart';
import '../../data/providers.dart';
import '../../l10n/gen/app_localizations.dart';
import '../session/session_controller.dart' show deviceTimezoneProvider;
import 'conflict_card.dart';
import 'import_controller.dart';
import 'import_logic.dart';
import 'import_prompt.dart';

/// .json 파일을 골라 바이트를 돌려준다(취소하면 null). 테스트에서 override 한다.
final importFilePickerProvider = Provider<Future<Uint8List?> Function()>((ref) {
  return () async {
    final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: const ['json']);
    return f?.readAsBytes();
  };
});

/// 이 길이를 넘는 파일은 입력칸에 넣지 않고 따로 들고 있는다(느려지지 않게).
const _inlineLimit = 20000;

class ImportPage extends ConsumerStatefulWidget {
  const ImportPage({super.key});

  @override
  ConsumerState<ImportPage> createState() => _ImportPageState();
}

class _ImportPageState extends ConsumerState<ImportPage> {
  final _text = TextEditingController();
  String _client = importClientNames.first;

  /// 큰 파일 내용. 있으면 입력칸 대신 이것을 쓴다.
  String? _fileText;
  String? _inputError;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  String _clientLabel(AppLocalizations l, String name) => switch (name) {
    'Claude' => l.importClientClaude,
    'ChatGPT' => l.importClientChatGpt,
    'Gemini' => l.importClientGemini,
    _ => l.importClientOther,
  };

  Future<void> _paste() async {
    final l = AppLocalizations.of(context);
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final t = data?.text;
    if (t == null || t.trim().isEmpty) {
      setState(() => _inputError = l.importClipboardEmpty);
      return;
    }
    setState(() {
      _fileText = null;
      _inputError = null;
      _text.text = t;
    });
  }

  Future<void> _pickFile() async {
    final l = AppLocalizations.of(context);
    final bytes = await ref.read(importFilePickerProvider)();
    if (bytes == null || !mounted) return;
    try {
      var s = utf8.decode(bytes);
      if (s.startsWith('﻿')) s = s.substring(1);
      setState(() {
        _inputError = null;
        if (s.length > _inlineLimit) {
          _fileText = s;
          _text.clear();
        } else {
          _fileText = null;
          _text.text = s;
        }
      });
    } on FormatException {
      setState(() => _inputError = l.importFileReadError);
    }
  }

  Future<void> _copyPrompt() async {
    final l = AppLocalizations.of(context);
    final repo = ref.read(importRepositoryProvider);
    final tz = await ref.read(deviceTimezoneProvider)();
    final now = ref.read(clockProvider)().toLocal();
    final unit = ref.read(settingsProvider).weightUnit == WeightUnit.KG ? 'kg' : 'lb';
    String two(int n) => n.toString().padLeft(2, '0');
    final prompt = buildImportPrompt(
      schemaUrl: repo.importSchemaUrl,
      programSchemaUrl: repo.programSchemaUrl,
      today: '${now.year.toString().padLeft(4, '0')}-${two(now.month)}-${two(now.day)}',
      tz: tz,
      unit: unit,
    );
    await Clipboard.setData(ClipboardData(text: prompt));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.importPromptCopied)));
  }

  void _startPreview() {
    final l = AppLocalizations.of(context);
    final r = parseBundle(_fileText ?? _text.text);
    switch (r) {
      case BundleParseError(:final problem, :final line, :final column):
        setState(() {
          _inputError = switch (problem) {
            BundleParseProblem.empty => l.importParseEmpty,
            BundleParseProblem.notObject => l.importParseNotObject,
            BundleParseProblem.syntax => l.importParseError(line, column),
          };
        });
      case BundleParsed(:final bundle):
        setState(() => _inputError = null);
        ref.read(importControllerProvider.notifier).start(bundle, _client);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final s = ref.watch(importControllerProvider);
    return Scaffold(
      appBar: AppBar(title: Text(l.importTitle)),
      body: switch (s.step) {
        ImportStep.input => _input(l, s),
        ImportStep.working => _working(l, s),
        ImportStep.preview => _PreviewView(state: s),
        ImportStep.done => _ResultView(state: s),
      },
    );
  }

  Widget _input(AppLocalizations l, ImportState s) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(l.importInputIntro),
        const SizedBox(height: 12),
        if (_fileText != null)
          Card(
            child: ListTile(
              leading: const Icon(Icons.description_outlined),
              title: Text(l.importFileLoaded((_fileText!.length / 1024).ceil())),
              trailing: TextButton(
                key: const ValueKey('import-clear-file'),
                onPressed: () => setState(() => _fileText = null),
                child: Text(l.importClear),
              ),
            ),
          )
        else
          TextField(
            key: const ValueKey('import-text'),
            controller: _text,
            minLines: 8,
            maxLines: 14,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            decoration: InputDecoration(hintText: l.importPasteHint, border: const OutlineInputBorder()),
          ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              key: const ValueKey('import-paste'),
              onPressed: _paste,
              icon: const Icon(Icons.content_paste),
              label: Text(l.importPasteClipboard),
            ),
            OutlinedButton.icon(
              key: const ValueKey('import-pick-file'),
              onPressed: _pickFile,
              icon: const Icon(Icons.folder_open),
              label: Text(l.importPickFile),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text(l.importClientLabel, style: theme.textTheme.titleSmall),
        Wrap(
          spacing: 8,
          children: [
            for (final n in importClientNames)
              ChoiceChip(
                key: ValueKey('import-client-$n'),
                label: Text(_clientLabel(l, n)),
                selected: _client == n,
                onSelected: (_) => setState(() => _client = n),
              ),
          ],
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          key: const ValueKey('import-copy-prompt'),
          onPressed: _copyPrompt,
          icon: const Icon(Icons.copy),
          label: Text(l.importCopyPrompt),
        ),
        if (_inputError != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_inputError!, key: const ValueKey('import-input-error'), style: TextStyle(color: theme.colorScheme.error)),
          ),
        if (s.error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              s.networkError ? l.importErrorNetwork : l.importErrorGeneric(s.error!),
              key: const ValueKey('import-error'),
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        if (s.validationErrors.isNotEmpty) _validation(l, s),
        const SizedBox(height: 16),
        FilledButton(
          key: const ValueKey('import-preview'),
          onPressed: _startPreview,
          child: Text(l.importPreviewButton),
        ),
      ],
    );
  }

  Widget _validation(AppLocalizations l, ImportState s) {
    final theme = Theme.of(context);
    return Card(
      key: const ValueKey('import-validation'),
      color: theme.colorScheme.errorContainer,
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l.importValidationTitle, style: theme.textTheme.titleSmall),
            Text(l.importValidationHint),
            const SizedBox(height: 6),
            for (final d in s.validationErrors)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('${d.path.isEmpty ? '/' : d.path}: ${d.message}', style: theme.textTheme.bodySmall),
              ),
          ],
        ),
      ),
    );
  }

  Widget _working(AppLocalizations l, ImportState s) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const CircularProgressIndicator(),
        const SizedBox(height: 12),
        Text(l.importPreviewing),
        if (s.total > 1) Text(l.importChunkProgress(s.index + 1, s.total)),
      ],
    ),
  );
}

String _kindLabel(AppLocalizations l, String kind) => switch (kind) {
  'exercises' => l.importCountKindExercises,
  'programs' => l.importCountKindPrograms,
  'startPrograms' || 'programInstances' => l.importCountKindStartPrograms,
  'sessions' => l.importCountKindSessions,
  'bodyMeasurements' => l.importCountKindBodyMeasurements,
  _ => kind,
};

String _statusLabel(AppLocalizations l, String status, int n) => switch (status) {
  'NEW' => l.importCountNew(n),
  'UNCHANGED' => l.importCountUnchanged(n),
  'REPLACE' => l.importCountReplace(n),
  'SKIP' => l.importCountSkip(n),
  _ => '$status $n',
};

class _PreviewView extends ConsumerWidget {
  final ImportState state;
  const _PreviewView({required this.state});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final ctrl = ref.read(importControllerProvider.notifier);
    final unit = ref.watch(settingsProvider).weightUnit;
    final p = state.preview!;
    final conflicts = state.conflicts;
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (state.total > 1) ...[
                Text(
                  l.importChunkProgress(state.index + 1, state.total),
                  key: const ValueKey('import-progress'),
                  style: theme.textTheme.titleMedium,
                ),
                Text(l.importChunkInfo(state.total)),
                const SizedBox(height: 8),
              ],
              Text(l.importPreviewTitle, style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              for (final e in p.counts.entries)
                if (e.value.values.any((n) => n > 0))
                  Padding(
                    key: ValueKey('count-${e.key}'),
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(
                      '${_kindLabel(l, e.key)}  ${[
                        for (final s in e.value.entries)
                          if (s.value > 0) _statusLabel(l, s.key, s.value),
                      ].join(' · ')}',
                    ),
                  ),
              const SizedBox(height: 12),
              if (conflicts.isEmpty)
                Text(l.importNoConflicts, key: const ValueKey('import-no-conflicts'))
              else ...[
                Row(
                  children: [
                    Expanded(child: Text(l.importConflictsTitle(conflicts.length), style: theme.textTheme.titleMedium)),
                    TextButton(
                      key: const ValueKey('import-skip-all'),
                      onPressed: ctrl.skipAll,
                      child: Text(l.importSkipAll),
                    ),
                  ],
                ),
                for (final c in conflicts)
                  ConflictCard(
                    key: ValueKey(c.conflictId),
                    conflict: c,
                    resolution: state.resolutions[c.conflictId],
                    unit: unit,
                    onChanged: (r) => ctrl.setResolution(c.conflictId, r),
                  ),
              ],
              if (state.error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    state.networkError ? l.importErrorNetwork : l.importErrorGeneric(state.error!),
                    key: const ValueKey('import-error'),
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (state.saving) const LinearProgressIndicator(),
                if (!state.allResolved)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(l.importResolveAllHint, style: theme.textTheme.bodySmall),
                  ),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    key: const ValueKey('import-save'),
                    onPressed: state.canSave ? ctrl.save : null,
                    child: Text(state.saving ? l.importSaving : l.importSave),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ResultView extends StatelessWidget {
  final ImportState state;
  const _ResultView({required this.state});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final total = <String, int>{};
    for (final b in state.batches) {
      for (final e in b.summary.entries) {
        total[e.key] = (total[e.key] ?? 0) + e.value;
      }
    }
    String label(String k, int n) => switch (k) {
      'exercises' => l.importSummaryExercises(n),
      'programs' => l.importSummaryPrograms(n),
      'instances' || 'startPrograms' || 'programInstances' => l.importSummaryInstances(n),
      'sessions' => l.importSummarySessions(n),
      'body' || 'bodyMeasurements' => l.importSummaryBody(n),
      'replaced' => l.importSummaryReplaced(n),
      _ => '$k $n',
    };
    final lines = [for (final e in total.entries) if (e.value > 0) label(e.key, e.value)];
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Icon(Icons.check_circle, size: 56, color: theme.colorScheme.primary),
        const SizedBox(height: 8),
        Center(child: Text(l.importResultTitle, style: theme.textTheme.titleLarge)),
        const SizedBox(height: 12),
        if (lines.isEmpty)
          Center(child: Text(l.importResultNothing))
        else
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [for (final t in lines) Chip(label: Text(t))],
          ),
        const SizedBox(height: 24),
        for (var i = 0; i < state.batches.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: OutlinedButton(
              key: ValueKey('import-history-$i'),
              onPressed: () => context.push(Routes.aiHistoryDetail(state.batches[i].id)),
              child: Text(
                state.batches.length > 1
                    ? '${l.importViewHistory} (${l.importChunkProgress(i + 1, state.batches.length)})'
                    : l.importViewHistory,
              ),
            ),
          ),
        FilledButton(
          key: const ValueKey('import-done'),
          onPressed: () => context.canPop() ? context.pop() : context.go(Routes.home),
          child: Text(l.importDone),
        ),
      ],
    );
  }
}
