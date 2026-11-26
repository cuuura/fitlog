import 'package:material_ui/material_ui.dart';

import '../../l10n/gen/app_localizations.dart';

/// 저장된 토큰을 확인하는 동안 보여준다.
class SplashPage extends StatelessWidget {
  const SplashPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(AppLocalizations.of(context).appTitle,
                style: t.textTheme.headlineLarge?.copyWith(fontWeight: FontWeight.w700, color: t.colorScheme.primary)),
            const SizedBox(height: 24),
            const CircularProgressIndicator(),
          ],
        ),
      ),
    );
  }
}
