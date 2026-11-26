// 저장소 Provider. 지금은 메모리 구현이고, B3가 drift 구현으로 바꾼다.
// 화면은 이 Provider만 읽는다. 테스트는 overrideWithValue로 바꿔 끼운다.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/repositories.dart';
import 'memory/memory_repositories.dart';

final exerciseRepositoryProvider = Provider<ExerciseRepository>((ref) => MemoryExerciseRepository());
final sessionRepositoryProvider = Provider<SessionRepository>((ref) => MemorySessionRepository());
final bodyRepositoryProvider = Provider<BodyRepository>((ref) => MemoryBodyRepository());
final syncServiceProvider = Provider<SyncService>((ref) => NoopSyncService());
final localDataStoreProvider = Provider<LocalDataStore>((ref) => NoopLocalDataStore());
