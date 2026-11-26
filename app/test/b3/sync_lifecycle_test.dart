import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:fitlog/data/memory/memory_repositories.dart';
import 'package:fitlog/data/providers.dart';
import 'package:fitlog/data/sync/sync_lifecycle.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_server.dart';

void main() {
  testWidgets('앱 시작·포그라운드 복귀·네트워크 복구에서 syncNow', (tester) async {
    final spy = SpySync();
    final net = StreamController<List<ConnectivityResult>>();
    addTearDown(net.close);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        syncServiceProvider.overrideWithValue(spy),
        exerciseRepositoryProvider.overrideWithValue(MemoryExerciseRepository()),
        connectivityStreamProvider.overrideWithValue(net.stream),
      ],
      child: const Directionality(textDirection: TextDirection.ltr, child: SyncLifecycle(child: SizedBox())),
    ));
    await tester.pump();
    expect(spy.syncNows, 1, reason: '앱 시작');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(spy.syncNows, 2, reason: '포그라운드 복귀');

    net.add([ConnectivityResult.none]);
    await tester.pump();
    expect(spy.syncNows, 2);
    net.add([ConnectivityResult.wifi]);
    await tester.pump();
    expect(spy.syncNows, 3, reason: '네트워크 복구');
  });
}
