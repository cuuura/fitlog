// 저장소 Provider. 화면은 이 Provider만 읽는다. 테스트는 overrideWithValue로
// data/memory 구현을 끼운다. 실제 구현은 drift 로컬 DB + outbox 동기화(data/local, data/sync).
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/repositories.dart';
import 'local/local_providers.dart';

final exerciseRepositoryProvider = Provider<ExerciseRepository>((ref) => ref.watch(driftExerciseRepositoryProvider));
final sessionRepositoryProvider = Provider<SessionRepository>((ref) => ref.watch(driftSessionRepositoryProvider));
final bodyRepositoryProvider = Provider<BodyRepository>((ref) => ref.watch(driftBodyRepositoryProvider));
final syncServiceProvider = Provider<SyncService>((ref) => ref.watch(syncEngineProvider));
final localDataStoreProvider = Provider<LocalDataStore>((ref) => ref.watch(driftLocalDataStoreProvider));
