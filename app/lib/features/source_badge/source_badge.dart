// B2 소유. 데이터가 AI·가져오기로 만들어졌음을 알리는 작은 칩.
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/routes.dart';
import '../../l10n/gen/app_localizations.dart';

/// [source]는 SessionSource·ProgramSource·MeasurementSource 등 이름이 AI_JSON·AI_MCP·IMPORT인 enum(또는 null).
/// 그 외 값이면 아무것도 그리지 않는다. [importBatchId]가 있으면 탭해서 묶음 상세로 간다.
class SourceBadge extends StatelessWidget {
  const SourceBadge({super.key, required this.source, this.importBatchId});
  final Enum? source;
  final String? importBatchId;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final (String, IconData)? spec = switch (source?.name) {
      'AI_JSON' => (l.sourceAiJson, Icons.auto_awesome),
      'AI_MCP' => (l.sourceAiMcp, Icons.hub_outlined),
      'IMPORT' => (l.sourceImport, Icons.file_download_outlined),
      _ => null,
    };
    if (spec == null) return const SizedBox.shrink();
    final id = importBatchId;
    final label = Text(spec.$1);
    final icon = Icon(spec.$2, size: 16);
    return id == null
        ? Chip(avatar: icon, label: label, visualDensity: VisualDensity.compact, padding: EdgeInsets.zero)
        : ActionChip(
            avatar: icon,
            label: label,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            onPressed: () => context.push(Routes.aiHistoryDetail(id)),
          );
  }
}
