// B3 소유. 동기화 트리거를 앱 수명에 붙이는 위젯: 앱 시작, 포그라운드 복귀, 네트워크 복구, 로그인 완료.
// (세트 완료 후 5초 디바운스와 세션 종료는 저장소가 SyncService를 직접 부른다.)
// 사용(리드): app.dart의 MaterialApp.router를 SyncLifecycle(child: ...)로 감싼다.
import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_controller.dart';
import '../providers.dart';

/// 네트워크 상태 스트림. 테스트는 override한다.
final connectivityStreamProvider = Provider<Stream<List<ConnectivityResult>>>(
  (ref) => Connectivity().onConnectivityChanged,
);

class SyncLifecycle extends ConsumerStatefulWidget {
  final Widget child;
  const SyncLifecycle({super.key, required this.child});

  @override
  ConsumerState<SyncLifecycle> createState() => _SyncLifecycleState();
}

class _SyncLifecycleState extends ConsumerState<SyncLifecycle> {
  late final AppLifecycleListener _lifecycle;
  StreamSubscription<List<ConnectivityResult>>? _net;
  bool _wasOffline = false;

  bool get _signedIn => ref.read(authControllerProvider) == AuthStatus.signedIn;

  void _trigger({bool refreshExercises = false}) {
    if (!_signedIn) return;
    unawaited(ref.read(syncServiceProvider).syncNow());
    if (refreshExercises) unawaited(ref.read(exerciseRepositoryProvider).refreshFromServer());
  }

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _trigger);
    _net = ref.read(connectivityStreamProvider).listen((results) {
      final offline = results.isEmpty || results.every((r) => r == ConnectivityResult.none);
      if (_wasOffline && !offline) _trigger();
      _wasOffline = offline;
    });
    // 앱 시작
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _trigger(refreshExercises: true);
    });
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _net?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 로그인이 끝나면(또는 계정이 바뀌면) 바로 한 번 맞춘다.
    ref.listen(authControllerProvider, (prev, next) {
      if (next == AuthStatus.signedIn && prev != AuthStatus.signedIn) _trigger(refreshExercises: true);
    });
    return widget.child;
  }
}
