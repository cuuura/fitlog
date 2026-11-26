// B2 소유. 홈 상단 "AI가 삭제를 요청했어요 (N건)" 배너. 앱이 포그라운드로 돌아오면 건수를 다시 읽는다.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/routes.dart';
import '../../l10n/gen/app_localizations.dart';
import 'deletion_providers.dart';

class PendingDeletionBanner extends ConsumerStatefulWidget {
  const PendingDeletionBanner({super.key});

  @override
  ConsumerState<PendingDeletionBanner> createState() => _PendingDeletionBannerState();
}

class _PendingDeletionBannerState extends ConsumerState<PendingDeletionBanner> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: () => ref.invalidate(pendingDeletionCountProvider));
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final n = ref.watch(pendingDeletionCountProvider).value ?? 0;
    if (n <= 0) return const SizedBox.shrink();
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        key: const Key('home-deletion-banner'),
        color: scheme.errorContainer,
        child: ListTile(
          leading: Icon(Icons.delete_sweep_outlined, color: scheme.onErrorContainer),
          title: Text(l.deletionBanner(n), style: TextStyle(color: scheme.onErrorContainer)),
          trailing: Icon(Icons.chevron_right, color: scheme.onErrorContainer),
          onTap: () async {
            await context.push(Routes.deletionRequests);
            if (mounted) ref.invalidate(pendingDeletionCountProvider);
          },
        ),
      ),
    );
  }
}
