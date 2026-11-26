import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/config.dart';
import '../../l10n/gen/app_localizations.dart';

/// 처리방침 주소: {API_BASE_URL}/privacy.
Uri privacyPolicyUri([String baseUrl = AppConfig.apiBaseUrl]) {
  final base = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
  return Uri.parse('$base/privacy');
}

/// 외부 브라우저로 연다. 실패하면 false.
Future<bool> openExternalUrl(Uri uri) async {
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}

/// 설정 화면 하단에 넣는 "개인정보 처리방침" 항목. 리드가 settings_page.dart에 한 줄로 붙인다.
class PrivacyPolicyTile extends StatelessWidget {
  const PrivacyPolicyTile({super.key, this.open = openExternalUrl, this.uri});

  final Future<bool> Function(Uri uri) open;
  final Uri? uri;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    return ListTile(
      leading: const Icon(Icons.privacy_tip_outlined),
      title: Text(l.releasePrivacyPolicy),
      subtitle: Text(l.releasePrivacyPolicySubtitle),
      trailing: const Icon(Icons.open_in_new),
      onTap: () async {
        final ok = await open(uri ?? privacyPolicyUri());
        if (!ok) messenger.showSnackBar(SnackBar(content: Text(l.releasePrivacyOpenFailed)));
      },
    );
  }
}
