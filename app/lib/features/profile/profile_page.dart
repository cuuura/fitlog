import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/dto.dart';
import '../../core/settings/settings_controller.dart';
import '../../l10n/gen/app_localizations.dart';
import 'profile_sheets.dart';

/// BDY-5 키·성별·출생 연도. Settings 필드로 저장한다. 행을 누르면 그 항목 하나를 고치는 시트가 열린다.
class ProfilePage extends ConsumerWidget {
  const ProfilePage({super.key});

  static const minHeightCm = 50;
  static const maxHeightCm = 260;
  static const minBirthYear = 1900;

  static String _trim(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final s = ref.watch(settingsProvider);
    final unset = l.profileValueEmpty;
    final sexText = switch (s.sex) {
      Sex.MALE => l.profileSexMale,
      Sex.FEMALE => l.profileSexFemale,
      Sex.OTHER => l.profileSexOther,
      null => unset,
    };
    return Scaffold(
      appBar: AppBar(title: Text(l.profileTitle)),
      body: ListView(
        children: [
          ListTile(
            key: const Key('profile-height'),
            title: Text(l.profileHeight),
            subtitle: Text(s.heightCm == null ? unset : '${_trim(s.heightCm!)} cm'),
            onTap: () => showHeightSheet(context, ref),
          ),
          ListTile(
            key: const Key('profile-sex'),
            title: Text(l.profileSex),
            subtitle: Text(sexText),
            onTap: () => showSexSheet(context, ref),
          ),
          ListTile(
            key: const Key('profile-birth'),
            title: Text(l.profileBirthYear),
            subtitle: Text(s.birthYear?.toString() ?? unset),
            onTap: () => showBirthYearSheet(context, ref),
          ),
        ],
      ),
    );
  }
}
