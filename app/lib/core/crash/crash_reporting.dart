// B3 소유. Sentry 크래시 리포팅. SENTRY_DSN(dart-define)이 없거나 사용자가 껐으면 아예 초기화하지 않는다.
// 끄고 켜기는 다음 실행부터 적용된다.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'pii_scrubber.dart';

abstract final class CrashConfig {
  static const dsn = String.fromEnvironment('SENTRY_DSN');
  static const prefKey = 'crash.reporting.enabled';
}

/// DSN이 들어 있는 빌드인가(없으면 설정 화면에서 토글을 숨긴다).
final crashReportingAvailableProvider = Provider<bool>((_) => CrashConfig.dsn.isNotEmpty);

Future<bool> loadCrashReportingEnabled() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(CrashConfig.prefKey) ?? true;
  } catch (_) {
    return true;
  }
}

Future<void> saveCrashReportingEnabled(bool v) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(CrashConfig.prefKey, v);
}

/// 설정 화면 토글의 값. 저장은 shared_preferences, 효과는 다음 실행부터.
class CrashReportingToggle extends Notifier<bool> {
  @override
  bool build() {
    Future.microtask(() async {
      final v = await loadCrashReportingEnabled();
      if (ref.mounted) state = v;
    });
    return true;
  }

  Future<void> set(bool v) async {
    final before = state;
    state = v;
    try {
      await saveCrashReportingEnabled(v);
    } catch (_) {
      if (ref.mounted) state = before;
      rethrow;
    }
  }
}

final crashReportingEnabledProvider = NotifierProvider<CrashReportingToggle, bool>(CrashReportingToggle.new);

/// 켜져 있으면 Sentry로 감싸서, 아니면 그냥 [appRunner]를 실행한다.
Future<void> runWithCrashReporting(
  FutureOr<void> Function() appRunner, {
  String dsn = CrashConfig.dsn,
  Future<bool> Function() isEnabled = loadCrashReportingEnabled,
}) async {
  if (dsn.isEmpty || !await isEnabled()) {
    await appRunner();
    return;
  }
  await SentryFlutter.init((o) {
    configureSentry(o);
    o.dsn = dsn;
  }, appRunner: appRunner);
}

/// 개인정보를 보내지 않는 옵션. 테스트에서 직접 확인한다.
void configureSentry(SentryFlutterOptions o) {
  o.sendDefaultPii = false;
  o.attachScreenshot = false;
  o.attachViewHierarchy = false;
  o.maxBreadcrumbs = 50;
  o.environment = kReleaseMode ? 'production' : 'development';
  o.beforeSend = (event, hint) => scrubEvent(event);
  o.beforeBreadcrumb = (b, hint) => scrubBreadcrumb(b);
}
