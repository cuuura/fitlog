import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/dto.dart';
import '../../core/clock.dart';
import '../../core/ids.dart';
import '../../core/settings/settings_controller.dart';
import '../../core/units.dart';
import '../../data/providers.dart';
import '../../l10n/gen/app_localizations.dart';
import '../source_badge/source_badge.dart';

/// BDY-1 체중 기록(최신순, 설정 단위로 표시). 저장은 항상 kg.
class BodyWeightPage extends ConsumerStatefulWidget {
  const BodyWeightPage({super.key});

  static const minKg = 20.0;
  static const maxKg = 400.0;

  @override
  ConsumerState<BodyWeightPage> createState() => _BodyWeightPageState();
}

final _measurementsProvider = StreamProvider.autoDispose<List<BodyMeasurement>>(
  (ref) => ref.watch(bodyRepositoryProvider).watchMeasurements(),
);

class _BodyWeightPageState extends ConsumerState<BodyWeightPage> {
  final _input = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final l = AppLocalizations.of(context);
    final unit = ref.read(settingsProvider).weightUnit;
    final v = double.tryParse(_input.text.trim().replaceAll(',', '.'));
    final kg = v == null ? null : Units.fromDisplay(v, unit);
    if (kg == null || kg < BodyWeightPage.minKg || kg > BodyWeightPage.maxKg) {
      setState(() => _error = l.bodyInvalid(
            Units.format(BodyWeightPage.minKg, unit, withUnit: false),
            Units.format(BodyWeightPage.maxKg, unit, withUnit: false),
            _unitLabel(unit),
          ));
      return;
    }
    setState(() => _error = null);
    await ref.read(bodyRepositoryProvider).add(BodyMeasurement(
          id: newId(),
          measuredAt: ref.read(clockProvider)(),
          weightKg: kg,
        ));
    _input.clear();
  }

  Future<void> _delete(BodyMeasurement m) async {
    final l = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        content: Text(l.bodyDeleteConfirm),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(l.commonCancel)),
          TextButton(key: const Key('dialogConfirm'), onPressed: () => Navigator.pop(c, true), child: Text(l.commonDelete)),
        ],
      ),
    );
    if (ok == true) await ref.read(bodyRepositoryProvider).delete(m.id);
  }

  static String _unitLabel(WeightUnit u) => u == WeightUnit.KG ? 'kg' : 'lb';

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final unit = ref.watch(settingsProvider.select((s) => s.weightUnit));
    final items = ref.watch(_measurementsProvider);
    final fmt = DateFormat.yMd(Localizations.localeOf(context).toString()).add_Hm();

    return Scaffold(
      appBar: AppBar(title: Text(l.bodyTitle)),
      body: Column(
        children: [
          Expanded(
            child: items.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text(l.commonError)),
              data: (list) => list.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(l.bodyEmpty, textAlign: TextAlign.center),
                      ),
                    )
                  : ListView.separated(
                      itemCount: list.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final m = list[i];
                        return ListTile(
                          key: Key('body_${m.id}'),
                          title: Row(
                            children: [
                              Text(Units.format(m.weightKg, unit)),
                              if (m.source == MeasurementSource.AI_JSON ||
                                  m.source == MeasurementSource.AI_MCP ||
                                  m.source == MeasurementSource.IMPORT) ...[
                                const SizedBox(width: 8),
                                SourceBadge(key: Key('source-${m.id}'), source: m.source, importBatchId: m.importBatchId),
                              ],
                            ],
                          ),
                          subtitle: Text(fmt.format(m.measuredAt.toLocal())),
                          trailing: IconButton(
                            tooltip: l.bodyDeleteTooltip,
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => _delete(m),
                          ),
                        );
                      },
                    ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('bodyInput'),
                      controller: _input,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
                      decoration: InputDecoration(labelText: l.bodyWeightLabel(_unitLabel(unit)), errorText: _error),
                      onSubmitted: (_) => _add(),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: FilledButton(key: const Key('bodyAdd'), onPressed: _add, child: Text(l.bodyAdd)),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
