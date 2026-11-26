// B3 소유. drift 구현 Provider. data/providers.dart(리드 소유)가 이 Provider들을 읽도록 바꿔야 한다
// (정확한 변경은 B3 보고서 참고).
import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_providers.dart';
import '../../core/clock.dart';
import '../../domain/repositories.dart';
import '../sync/sync_engine.dart';
import 'app_database.dart';
import 'drift_repositories.dart';

final appDatabaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase(driftDatabase(name: 'fitlog'));
  ref.onDispose(db.close);
  return db;
});

final syncEngineProvider = Provider<SyncEngine>((ref) {
  final engine = SyncEngine(db: ref.watch(appDatabaseProvider), api: ref.watch(apiClientProvider), clock: ref.watch(clockProvider));
  ref.onDispose(engine.dispose);
  return engine;
});

final driftExerciseRepositoryProvider = Provider<ExerciseRepository>((ref) => DriftExerciseRepository(
    ref.watch(appDatabaseProvider), ref.watch(syncEngineProvider), ref.watch(apiClientProvider),
    clock: ref.watch(clockProvider)));

final driftSessionRepositoryProvider = Provider<SessionRepository>((ref) =>
    DriftSessionRepository(ref.watch(appDatabaseProvider), ref.watch(syncEngineProvider), clock: ref.watch(clockProvider)));

final driftBodyRepositoryProvider = Provider<BodyRepository>((ref) =>
    DriftBodyRepository(ref.watch(appDatabaseProvider), ref.watch(syncEngineProvider), clock: ref.watch(clockProvider)));

final driftLocalDataStoreProvider = Provider<LocalDataStore>(
    (ref) => DriftLocalDataStore(ref.watch(appDatabaseProvider), engine: ref.watch(syncEngineProvider)));
