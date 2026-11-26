import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/dto.dart';
import '../../core/clock.dart';
import '../../core/settings/settings_controller.dart';
import '../../l10n/gen/app_localizations.dart';

/// BDY-5 키·성별·출생 연도. Settings 필드로 저장한다.
class ProfilePage extends ConsumerStatefulWidget {
  const ProfilePage({super.key});

  static const minHeightCm = 50;
  static const maxHeightCm = 260;
  static const minBirthYear = 1900;

  @override
  ConsumerState<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends ConsumerState<ProfilePage> {
  final _height = TextEditingController();
  final _birth = TextEditingController();
  Sex? _sex;
  bool _dirty = false;
  bool _saving = false;
  String? _heightError;
  String? _birthError;

  @override
  void initState() {
    super.initState();
    _fill(ref.read(settingsProvider));
    // 캐시·서버에서 늦게 읽힌 값은 사용자가 편집하기 전에만 반영한다.
    ref.listenManual(settingsProvider, (_, s) {
      if (!_dirty) setState(() => _fill(s));
    });
  }

  void _fill(Settings s) {
    _height.text = s.heightCm == null ? '' : _trim(s.heightCm!);
    _birth.text = s.birthYear?.toString() ?? '';
    _sex = s.sex;
  }

  static String _trim(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

  @override
  void dispose() {
    _height.dispose();
    _birth.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final l = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final maxYear = ref.read(clockProvider)().year;

    double? h;
    int? y;
    String? he, be;
    final ht = _height.text.trim().replaceAll(',', '.');
    if (ht.isNotEmpty) {
      h = double.tryParse(ht);
      if (h == null || h < ProfilePage.minHeightCm || h > ProfilePage.maxHeightCm) {
        he = l.profileHeightInvalid(ProfilePage.minHeightCm, ProfilePage.maxHeightCm);
      }
    }
    final bt = _birth.text.trim();
    if (bt.isNotEmpty) {
      y = int.tryParse(bt);
      if (y == null || y < ProfilePage.minBirthYear || y > maxYear) {
        be = l.profileBirthInvalid(ProfilePage.minBirthYear, maxYear);
      }
    }
    setState(() {
      _heightError = he;
      _birthError = be;
    });
    if (he != null || be != null) return;

    setState(() => _saving = true);
    try {
      final cur = ref.read(settingsProvider);
      await ref.read(settingsProvider.notifier).update(cur.copyWith(heightCm: () => h, sex: () => _sex, birthYear: () => y));
      _dirty = false;
      messenger.showSnackBar(SnackBar(content: Text(l.profileSaved)));
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(l.settingsSaveFailed)));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l.profileTitle)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            key: const Key('profileHeight'),
            controller: _height,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
            decoration: InputDecoration(
              labelText: l.profileHeight,
              errorText: _heightError,
              suffixIcon: IconButton(
                key: const Key('profileHeightClear'),
                tooltip: l.profileClear,
                icon: const Icon(Icons.clear),
                onPressed: () => setState(() {
                  _height.clear();
                  _heightError = null;
                  _dirty = true;
                }),
              ),
            ),
            onChanged: (_) => _dirty = true,
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<Sex?>(
            key: const Key('profileSex'),
            initialValue: _sex,
            decoration: InputDecoration(labelText: l.profileSex),
            items: [
              DropdownMenuItem(value: null, child: Text(l.profileSexUnset)),
              DropdownMenuItem(value: Sex.MALE, child: Text(l.profileSexMale)),
              DropdownMenuItem(value: Sex.FEMALE, child: Text(l.profileSexFemale)),
              DropdownMenuItem(value: Sex.OTHER, child: Text(l.profileSexOther)),
            ],
            onChanged: (v) {
              _dirty = true;
              _sex = v;
            },
          ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('profileBirth'),
            controller: _birth,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(4)],
            decoration: InputDecoration(
              labelText: l.profileBirthYear,
              errorText: _birthError,
              suffixIcon: IconButton(
                key: const Key('profileBirthClear'),
                tooltip: l.profileClear,
                icon: const Icon(Icons.clear),
                onPressed: () => setState(() {
                  _birth.clear();
                  _birthError = null;
                  _dirty = true;
                }),
              ),
            ),
            onChanged: (_) => _dirty = true,
          ),
          const SizedBox(height: 24),
          FilledButton(
            key: const Key('profileSave'),
            onPressed: _saving ? null : _save,
            child: Text(l.commonSave),
          ),
        ],
      ),
    );
  }
}
