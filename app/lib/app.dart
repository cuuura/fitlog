import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'core/api/server_wake.dart';
import 'core/router.dart';
import 'core/theme.dart';
import 'core/reminders/reminder_service.dart';
import 'data/sync/sync_lifecycle.dart';
import 'l10n/gen/app_localizations.dart';

class FitlogApp extends ConsumerWidget {
  const FitlogApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ReminderLifecycle(child: SyncLifecycle(
      child: MaterialApp.router(
        onGenerateTitle: (c) => AppLocalizations.of(c).appTitle,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: ThemeMode.system,
        routerConfig: ref.watch(routerProvider),
        builder: (context, child) => ServerWakingBanner(wake: ref.watch(serverWakeProvider), child: child ?? const SizedBox.shrink()),
        localizationsDelegates: [AppLocalizations.delegate, ...GlobalMaterialLocalizations.delegates],
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ));
  }
}

/// 잠든 서버를 깨우는 동안(첫 요청이 몇 초 넘게 걸릴 때) 화면 위쪽에 안내를 띄운다.
/// 화면(Navigator)은 항상 같은 자리에 두어 배너가 켜지고 꺼져도 상태를 잃지 않는다.
class ServerWakingBanner extends StatelessWidget {
  const ServerWakingBanner({super.key, required this.wake, required this.child});
  final ServerWake wake;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(child: child),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: ValueListenableBuilder<bool>(
            valueListenable: wake.waking,
            builder: (context, waking, _) {
              if (!waking) return const SizedBox.shrink();
              final t = Theme.of(context);
              return Material(
                color: t.colorScheme.secondaryContainer,
                child: SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Row(
                      children: [
                        const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            AppLocalizations.of(context).serverWaking,
                            key: const Key('serverWaking'),
                            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSecondaryContainer),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
