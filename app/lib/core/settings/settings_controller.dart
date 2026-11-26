// B1 소유. ACC-3 설정과 BDY-5 프로필(키·성별·생년). 다른 WP는 읽기만 한다:
//   final settings = ref.watch(settingsProvider);   // 항상 값이 있음(기본값부터 시작)
import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_providers.dart';
import '../api/dto.dart';
import '../auth/auth_controller.dart';

const settingsCacheKey = 'settings.v1';

/// 시작 시 캐시(shared_preferences)에서 즉시 읽고, 로그인되면 서버 값으로 갱신한다.
/// [update]는 낙관적으로 반영하고 서버 저장이 실패하면 되돌린 뒤 예외를 던진다.
class SettingsController extends Notifier<Settings> {
  int _rev = 0;
  Future<void> _queue = Future.value();

  @override
  Settings build() {
    Future.microtask(_loadCache);
    ref.listen<AuthStatus>(authControllerProvider, (prev, next) {
      if (next == AuthStatus.signedIn && prev != AuthStatus.signedIn) {
        unawaited(refreshFromServer());
      } else if (next == AuthStatus.signedOut && prev != null && prev != AuthStatus.unknown) {
        _reset();
      }
    }, fireImmediately: true);
    return const Settings();
  }

  Future<void> _loadCache() async {
    final rev = _rev;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(settingsCacheKey);
      if (raw == null || !ref.mounted || rev != _rev) return;
      state = Settings.fromJson((jsonDecode(raw) as Map).cast<String, Object?>());
    } catch (_) {}
  }

  Future<void> _saveCache(Settings s) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(settingsCacheKey, jsonEncode(s.toJson()));
    } catch (_) {}
  }

  Future<void> _reset() async {
    _rev++;
    state = const Settings();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(settingsCacheKey);
    } catch (_) {}
  }

  /// 서버 값으로 갱신. 그 사이 사용자가 바꾼 값이 있으면 덮어쓰지 않는다. 실패는 무시한다(캐시 유지).
  Future<void> refreshFromServer() async {
    final rev = _rev;
    try {
      final s = await ref.read(apiClientProvider).getSettings();
      if (!ref.mounted || rev != _rev) return;
      _rev++; // 아직 안 끝난 캐시 로드가 서버 값을 덮어쓰지 않게 한다.
      state = s;
      await _saveCache(s);
    } catch (_) {}
  }

  /// 낙관적 갱신. 서버 저장 실패 시 이전 값으로 되돌리고 예외([ApiException] 등)를 다시 던진다.
  Future<void> update(Settings next) {
    final prev = state;
    final rev = ++_rev;
    state = next;
    // 요청 순서를 지키려고 직렬화한다.
    final run = _queue.then((_) async {
      await _saveCache(next);
      try {
        await ref.read(apiClientProvider).putSettings(next);
      } catch (_) {
        if (ref.mounted && _rev == rev) {
          state = prev;
          await _saveCache(prev);
        }
        rethrow;
      }
    });
    _queue = run.then((_) {}, onError: (_) {});
    return run;
  }
}

final settingsProvider = NotifierProvider<SettingsController, Settings>(SettingsController.new);
