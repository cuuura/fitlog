// B2 소유. 홈 상단 "AI가 삭제를 요청했어요 (N건)" 배너. 앱이 포그라운드로 돌아오면 건수를 다시 읽는다.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/routes.dart';
import '../../core/theme.dart';
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
    final ai = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        key: const Key('home-deletion-banner'),
        color: ai.aiSoft,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.md),
          onTap: () async {
            await context.push(Routes.deletionRequests);
            if (mounted) ref.invalidate(pendingDeletionCountProvider);
          },
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Row(
                children: [
                  Icon(Icons.auto_awesome, color: ai.ai, size: 20),
                  const SizedBox(width: 10),
                  Expanded(child: Text(l.deletionBanner(n), style: TextStyle(color: ai.fg))),
                  Icon(Icons.chevron_right, color: ai.ai),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
