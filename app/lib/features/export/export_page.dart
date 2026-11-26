import 'package:fitlog/core/api/ai_dto.dart';
import 'package:fitlog/data/providers.dart';
import 'package:fitlog/l10n/gen/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'export_saver.dart';

enum _Kind { json, sets, body }

class ExportPage extends ConsumerStatefulWidget {
  const ExportPage({super.key});

  @override
  ConsumerState<ExportPage> createState() => _ExportPageState();
}

class _ExportPageState extends ConsumerState<ExportPage> {
  _Kind? _busy;
  bool _failed = false;
  bool _done = false;

  static String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';

  Future<void> _run(_Kind kind) async {
    if (_busy != null) return;
    setState(() {
      _busy = kind;
      _failed = false;
      _done = false;
    });
    try {
      final repo = ref.read(exportRepositoryProvider);
      final ymd = _ymd(DateTime.now());
      final (name, mime, content) = switch (kind) {
        _Kind.json => ('fitlog-$ymd.json', 'application/json', await repo.exportJson()),
        _Kind.sets => ('fitlog-sets-$ymd.csv', 'text/csv', await repo.exportCsv(CsvKind.sets)),
        _Kind.body => ('fitlog-body-$ymd.csv', 'text/csv', await repo.exportCsv(CsvKind.body)),
      };
      await ref.read(exportSaverProvider).save(fileName: name, content: content, mimeType: mime);
      if (mounted) setState(() => _done = true);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    Widget tile(_Kind k, IconData icon, String title, String desc) => ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(desc),
      isThreeLine: true,
      trailing: _busy == k ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)) : null,
      enabled: _busy == null || _busy == k,
      onTap: _busy == null ? () => _run(k) : null,
    );
    return Scaffold(
      appBar: AppBar(title: Text(l.exportTitle)),
      body: ListView(
        children: [
          if (_failed)
            ListTile(
              leading: Icon(Icons.error_outline, color: Theme.of(context).colorScheme.error),
              title: Text(l.exportFailed),
            ),
          if (_done) ListTile(leading: const Icon(Icons.check_circle_outline), title: Text(l.exportDone)),
          tile(_Kind.json, Icons.backup_outlined, l.exportJson, l.exportJsonDesc),
          tile(_Kind.sets, Icons.table_chart_outlined, l.exportSets, l.exportSetsDesc),
          tile(_Kind.body, Icons.monitor_weight_outlined, l.exportBody, l.exportBodyDesc),
        ],
      ),
    );
  }
}
