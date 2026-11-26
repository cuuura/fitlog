import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 테스트에서 시간을 고정하기 위한 시계. 항상 UTC를 돌려준다.
typedef Clock = DateTime Function();

final clockProvider = Provider<Clock>((ref) => () => DateTime.now().toUtc());
