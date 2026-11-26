// B2 소유. AI 삭제 요청 대기 건수(AI-5). 로그인 상태에서만 서버에 묻고, 오류면 0.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_controller.dart';
import '../../data/providers.dart';

final pendingDeletionCountProvider = FutureProvider<int>((ref) async {
  final status = ref.watch(authControllerProvider);
  if (status != AuthStatus.signedIn) return 0;
  try {
    return await ref.watch(deletionRequestRepositoryProvider).pendingCount();
  } catch (_) {
    return 0;
  }
});
