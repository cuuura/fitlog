import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'core/router.dart';
import 'core/theme.dart';
import 'data/sync/sync_lifecycle.dart';
import 'l10n/gen/app_localizations.dart';

class FitlogApp extends ConsumerWidget {
  const FitlogApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SyncLifecycle(
      child: MaterialApp.router(
        onGenerateTitle: (c) => AppLocalizations.of(c).appTitle,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: ThemeMode.system,
        routerConfig: ref.watch(routerProvider),
        localizationsDelegates: [AppLocalizations.delegate, ...GlobalMaterialLocalizations.delegates],
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    );
  }
}
