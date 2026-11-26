// B1 소유. 프로그램 상세: 이름·설명·날별 종목·세트 요약.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/program_dto.dart';
import '../../core/routes.dart';
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
    return Scaffold(
      appBar: AppBar(title: Text(async.value?.program.name ?? l.programsTitle)),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorRetry(error: e, onRetry: () => ref.invalidate(programViewProvider(programId))),
        data: (v) {
          final def = v.program.definition;
          final theme = Theme.of(context);
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
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
              const SizedBox(height: 16),
              Text(l.programDaysHeader, style: theme.textTheme.titleMedium),
              for (final day in programDays(def)) ...[
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          [day['name'] as String, if (day['weekday'] != null) weekdayLabel(l, day['weekday'] as String)].join(' · '),
                          style: theme.textTheme.titleSmall,
                        ),
                        const SizedBox(height: 8),
                        for (final ex in (day['exercises'] as List? ?? const []).cast<Map>())
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Text(
                              '${v.lifts[ex['lift']]?.name(context) ?? ex['lift']}  ${summarizeSets((ex['sets'] as List).cast())}',
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          );
        },
      ),
      floatingActionButton: async.hasValue
          ? FloatingActionButton.extended(
              onPressed: () => context.push(Routes.programStart(programId)),
              label: Text(l.programStartAction),
              icon: const Icon(Icons.play_arrow),
            )
          : null,
    );
  }
}
