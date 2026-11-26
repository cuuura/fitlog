// B2 소유. 골격은 메모리 구현(캐시 없음). B2가 오프라인 캐시 구현으로 바꾼다.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/repositories.dart';
import '../memory/memory_repositories.dart';
import '../providers.dart';

final planCacheImplProvider = Provider<PlanCache>((ref) => MemoryPlanCache(ref.watch(programRepositoryProvider)));
