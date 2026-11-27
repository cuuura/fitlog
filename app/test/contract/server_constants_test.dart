// 앱 상수가 서버 소스의 같은 상수와 어긋나면(예: 동의 버전) 서버 없이도 바로 잡는다.
// 사고 사례: 앱은 다른 동의 버전을 보내고 서버는 2026-11-01 을 요구해 동의 화면에서 영원히 못 나왔다.
import 'dart:io';

import 'package:fitlog/core/config.dart';
import 'package:fitlog/features/progress/progress_logic.dart';
import 'package:flutter_test/flutter_test.dart';

String? _serverSource(String relative) {
  final f = File('../server/src/main/kotlin/com/fitlog/$relative');
  return f.existsSync() ? f.readAsStringSync() : null;
}

void main() {
  test('동의 버전이 서버 CURRENT_CONSENT_VERSION 과 같다', () {
    final src = _serverSource('account/AccountRoutes.kt');
    if (src == null) return; // 앱만 따로 체크아웃한 경우
    final m = RegExp(r'const val CURRENT_CONSENT_VERSION = "([^"]+)"').firstMatch(src);
    expect(m, isNotNull, reason: '서버 상수 이름이 바뀌었다. 이 테스트도 고쳐야 한다');
    expect(AppConfig.consentVersion, m!.group(1));
  });

  test('sync push 묶음 크기(앱 200)가 서버 MAX_PUSH 이하', () {
    final src = _serverSource('sync/SyncPush.kt');
    if (src == null) return;
    final m = RegExp(r'const val MAX_PUSH = (\d+)').firstMatch(src);
    expect(m, isNotNull);
    expect(200, lessThanOrEqualTo(int.parse(m!.group(1)!)));
  });

  test('종목 추이 limit 은 서버 최대(PROGRESS_MAX_LIMIT) 이하', () {
    final src = _serverSource('stats/StatsRoutes.kt');
    if (src == null) return;
    final m = RegExp(r'const val PROGRESS_MAX_LIMIT = (\d+)').firstMatch(src);
    expect(m, isNotNull);
    expect(progressLimit, lessThanOrEqualTo(int.parse(m!.group(1)!)));
  });
}
