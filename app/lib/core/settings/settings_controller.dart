// B1 소유. ACC-3 설정과 BDY-5 프로필(키·성별·생년). 다른 WP는 읽기만 한다:
//   final settings = ref.watch(settingsProvider);   // 항상 값이 있음(기본값부터 시작)
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/dto.dart';

class SettingsController extends Notifier<Settings> {
  @override
  Settings build() => const Settings();

  Future<void> update(Settings next) async => state = next;
}

final settingsProvider = NotifierProvider<SettingsController, Settings>(SettingsController.new);
