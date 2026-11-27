// B1 소유. 프로그램 상세: 주 구조·규칙·시작 버튼.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/program_dto.dart';
import '../../core/routes.dart';
import '../../core/settings/settings_controller.dart';
import '../../core/theme.dart';
import '../../l10n/gen/app_localizations.dart';
import '../source_badge/source_badge.dart';
import 'program_common.dart';
import 'programs_providers.dart';

class ProgramDetailPage extends ConsumerWidget {
  const ProgramDetailPage({super.key, required this.programId});
  final String programId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final async = ref.watch(programViewProvider(programId));
    final unit = ref.watch(settingsProvider).weightUnit;
    final c = AppColors.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(async.value?.program.name ?? l.programsTitle)),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorRetry(error: e, onRetry: () => ref.invalidate(programViewProvider(programId))),
        data: (v) {
          final def = v.program.definition;
          final theme = Theme.of(context);
          final rules = programRuleEntries(l, def, unit);
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (v.program.source == ProgramSource.AI_JSON || v.program.source == ProgramSource.AI_MCP)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: SourceBadge(
                      key: const Key('program-source-badge'),
                      source: v.program.source,
                      importBatchId: v.program.importBatchId,
                    ),
                  ),
                ),
              Text(v.program.description ?? l.programNoDescription, style: theme.textTheme.bodyMedium),
              const SizedBox(height: 20),
              Text(l.progWeekStructure, style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Container(
                decoration: BoxDecoration(
                  border: Border.all(color: c.line),
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: Column(
                  children: [
                    for (final (i, day) in programDays(def).indexed) ...[
                      if (i > 0) Divider(height: 1, color: c.line),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 40,
                              child: Text(
                                day['weekday'] != null
                                    ? weekdayLabel(l, day['weekday'] as String)
                                    : (day['key'] as String? ?? '${i + 1}'),
                                style: theme.textTheme.titleSmall,
                              ),
                            ),
                            Expanded(
                              child: Text(
                                [
                                  for (final ex in (day['exercises'] as List? ?? const []).cast<Map>())
                                    '${v.lifts[ex['lift']]?.name(context) ?? ex['lift']}  ${summarizeSets((ex['sets'] as List).cast())}'.trim(),
                                ].join('\n'),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Text(l.progRules, style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Container(
                decoration: BoxDecoration(
                  border: Border.all(color: c.line),
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: Column(
                  children: [
                    for (final (i, r) in rules.indexed) ...[
                      if (i > 0) Divider(height: 1, color: c.line),
                      Padding(
                        padding: const EdgeInsets.all(14),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(r.icon, color: c.fg2),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(r.title, style: theme.textTheme.titleSmall),
                                  Text(r.body, style: theme.textTheme.bodySmall?.copyWith(color: c.fg2)),
                                  if (r.table.isNotEmpty) ...[
                                    const SizedBox(height: 6),
                                    Wrap(
                                      spacing: 8,
                                      runSpacing: 6,
                                      children: [
                                        for (final (range, inc) in r.table)
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                            decoration: BoxDecoration(
                                              color: c.surface2,
                                              borderRadius: BorderRadius.circular(AppRadius.sm),
                                            ),
                                            child: Text.rich(
                                              TextSpan(
                                                text: '$range ',
                                                style: theme.textTheme.bodySmall,
                                                children: [
                                                  TextSpan(
                                                    text: inc,
                                                    style: AppNum.table(context),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          );
        },
      ),
      bottomNavigationBar: async.hasValue
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: FilledButton(
                  key: const Key('program-start'),
                  onPressed: () => context.push(Routes.programStart(programId)),
                  child: Text(l.progStartCta),
                ),
              ),
            )
          : null,
    );
  }
}
