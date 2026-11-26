// B2 소유. 계획 캐시 Provider. 갱신 시점: 앱 시작(Provider 생성), 포그라운드 복귀,
// 세션 종료 후 동기화 직후(syncing -> idle), 인스턴스 변경 이벤트, 로그인.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_controller.dart';
import '../../domain/repositories.dart';
import '../providers.dart';
import 'prefs_plan_cache.dart';

final planCacheImplProvider = Provider<PlanCache>((ref) {
  final cache = PrefsPlanCache(
    programs: ref.watch(programRepositoryProvider),
    sessions: ref.watch(sessionRepositoryProvider),
  );
  void refresh() => unawaited(cache.refresh().catchError((_) {}));

  final subs = <StreamSubscription<dynamic>>[];
  subs.add(
    ref
        .read(programRepositoryProvider)
        .instanceChanges
        .listen((_) => refresh(), onError: (_) {}),
  );
  SyncPhase? prev;
  subs.add(
    ref.read(syncServiceProvider).watchStatus().listen((s) {
      if (prev == SyncPhase.syncing && s.phase == SyncPhase.idle) refresh();
      prev = s.phase;
    }, onError: (_) {}),
  );
  final lifecycle = AppLifecycleListener(onResume: refresh);

  ref.listen(authControllerProvider, (p, n) {
    if (n == AuthStatus.signedIn) {
      refresh();
    } else if (n == AuthStatus.signedOut) {
      unawaited(cache.clear());
    }
  });
  ref.onDispose(() {
    for (final s in subs) {
      s.cancel();
    }
    lifecycle.dispose();
    cache.dispose();
  });
  if (ref.read(authControllerProvider) == AuthStatus.signedIn) refresh();
  return cache;
});
