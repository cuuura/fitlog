import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/dto.dart';
import '../../core/clock.dart';
import '../../core/settings/settings_controller.dart';
import '../../core/ui/form_sheet.dart';
import '../../l10n/gen/app_localizations.dart';
import 'profile_page.dart';

String _trim(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

/// 키 입력 시트. 비워서 저장하면 키를 지운다. 프로필 화면과 체중 기록 화면이 함께 쓴다.
Future<void> showHeightSheet(BuildContext context, WidgetRef ref) =>
    showFormSheet<bool>(context, builder: (_) => const _HeightSheet());

/// 성별 선택 시트.
Future<void> showSexSheet(BuildContext context, WidgetRef ref) =>
    showFormSheet<bool>(context, builder: (_) => const _SexSheet());

/// 출생 연도 입력 시트. 비워서 저장하면 지운다.
Future<void> showBirthYearSheet(BuildContext context, WidgetRef ref) =>
    showFormSheet<bool>(context, builder: (_) => const _BirthSheet());

class _HeightSheet extends ConsumerStatefulWidget {
  const _HeightSheet();
  @override
  ConsumerState<_HeightSheet> createState() => _HeightSheetState();
}

class _HeightSheetState extends ConsumerState<_HeightSheet> {
  late final _c = TextEditingController(
    text: ref.read(settingsProvider).heightCm == null ? '' : _trim(ref.read(settingsProvider).heightCm!),
  );
  String? _error;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<bool?> _submit() async {
    final l = AppLocalizations.of(context);
    double? h;
    final t = _c.text.trim().replaceAll(',', '.');
    if (t.isNotEmpty) {
      h = double.tryParse(t);
      if (h == null || h < ProfilePage.minHeightCm || h > ProfilePage.maxHeightCm) {
        setState(() => _error = l.profileHeightInvalid(ProfilePage.minHeightCm, ProfilePage.maxHeightCm));
        return null;
      }
    }
    setState(() => _error = null);
    final cur = ref.read(settingsProvider);
    await ref.read(settingsProvider.notifier).update(cur.copyWith(heightCm: () => h));
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return FormSheet<bool>(
      title: l.profileHeight,
      submitLabel: l.commonSave,
      submitKey: const Key('profileSave'),
      failureMessage: (_) => l.settingsSaveFailed,
      onSubmit: _submit,
      children: [
        TextField(
          key: const Key('profileHeight'),
          controller: _c,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
          decoration: InputDecoration(labelText: l.profileHeight, errorText: _error),
        ),
      ],
    );
  }
}

class _BirthSheet extends ConsumerStatefulWidget {
  const _BirthSheet();
  @override
  ConsumerState<_BirthSheet> createState() => _BirthSheetState();
}

class _BirthSheetState extends ConsumerState<_BirthSheet> {
  late final _c = TextEditingController(text: ref.read(settingsProvider).birthYear?.toString() ?? '');
  String? _error;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<bool?> _submit() async {
    final l = AppLocalizations.of(context);
    final maxYear = ref.read(clockProvider)().year;
    int? y;
    final t = _c.text.trim();
    if (t.isNotEmpty) {
      y = int.tryParse(t);
      if (y == null || y < ProfilePage.minBirthYear || y > maxYear) {
        setState(() => _error = l.profileBirthInvalid(ProfilePage.minBirthYear, maxYear));
        return null;
      }
    }
    setState(() => _error = null);
    final cur = ref.read(settingsProvider);
    await ref.read(settingsProvider.notifier).update(cur.copyWith(birthYear: () => y));
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return FormSheet<bool>(
      title: l.profileBirthYear,
      submitLabel: l.commonSave,
      submitKey: const Key('profileSave'),
      failureMessage: (_) => l.settingsSaveFailed,
      onSubmit: _submit,
      children: [
        TextField(
          key: const Key('profileBirth'),
          controller: _c,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(4)],
          decoration: InputDecoration(labelText: l.profileBirthYear, errorText: _error),
        ),
      ],
    );
  }
}

class _SexSheet extends ConsumerStatefulWidget {
  const _SexSheet();
  @override
  ConsumerState<_SexSheet> createState() => _SexSheetState();
}

class _SexSheetState extends ConsumerState<_SexSheet> {
  late Sex? _sex = ref.read(settingsProvider).sex;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final options = <(Sex?, String)>[
      (null, l.profileSexUnset),
      (Sex.MALE, l.profileSexMale),
      (Sex.FEMALE, l.profileSexFemale),
      (Sex.OTHER, l.profileSexOther),
    ];
    return FormSheet<bool>(
      title: l.profileSex,
      submitLabel: l.commonSave,
      submitKey: const Key('profileSave'),
      failureMessage: (_) => l.settingsSaveFailed,
      onSubmit: () async {
        final cur = ref.read(settingsProvider);
        await ref.read(settingsProvider.notifier).update(cur.copyWith(sex: () => _sex));
        return true;
      },
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (v, label) in options)
              ChoiceChip(
                key: Key('profileSex-${v?.name ?? 'none'}'),
                label: Text(label),
                selected: _sex == v,
                onSelected: (_) => setState(() => _sex = v),
              ),
          ],
        ),
      ],
    );
  }
}
