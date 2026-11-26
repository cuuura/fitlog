import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'app.dart';
import 'core/crash/crash_reporting.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // SENTRY_DSN이 없거나 설정에서 껐으면 Sentry를 초기화하지 않고 그대로 실행한다.
  // 켜져 있으면 SentryFlutter가 FlutterError.onError / PlatformDispatcher.onError를 연결한다.
  await runWithCrashReporting(() => runApp(const ProviderScope(child: FitlogApp())));
}
