// B3 소유. 크래시 리포트에서 개인정보를 지우는 순수 함수들(테스트: test/v10_b3/crash_test.dart).
import 'package:sentry_flutter/sentry_flutter.dart';

final _email = RegExp(r'[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}');
final _bearer = RegExp(r'Bearer\s+[A-Za-z0-9._~+/=\-]+', caseSensitive: false);
final _jwt = RegExp(r'eyJ[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]*');
final _kv = RegExp(
  r'''(access[_-]?token|refresh[_-]?token|id[_-]?token|token|authorization|password|secret|api[_-]?key)(["']?\s*[:=]\s*["']?)[^\s"',&}]+''',
  caseSensitive: false,
);
final _longToken = RegExp(r'\b[A-Za-z0-9_\-]{32,}\b');

/// 이메일·토큰처럼 보이는 문자열을 가린다.
String scrubText(String input) {
  var s = input;
  s = s.replaceAll(_bearer, 'Bearer [token]');
  s = s.replaceAll(_jwt, '[token]');
  s = s.replaceAllMapped(_kv, (m) => '${m[1]}${m[2]}[token]');
  s = s.replaceAll(_email, '[email]');
  s = s.replaceAll(_longToken, '[token]');
  return s;
}

/// 이벤트에서 사용자·요청·HTTP 이력을 지우고 문자열을 가린다.
SentryEvent scrubEvent(SentryEvent event) {
  event.user = null;
  event.request = null;
  event.serverName = null;
  // ignore: deprecated_member_use
  event.extra = null;
  final msg = event.message;
  if (msg != null) {
    event.message = SentryMessage(
      scrubText(msg.formatted),
      template: msg.template == null ? null : scrubText(msg.template!),
    );
  }
  for (final e in event.exceptions ?? const <SentryException>[]) {
    final v = e.value;
    if (v != null) e.value = scrubText(v);
  }
  event.breadcrumbs = [for (final b in event.breadcrumbs ?? const <Breadcrumb>[]) ?scrubBreadcrumb(b)];
  return event;
}

/// http 이력은 URL에 id가 섞일 수 있어 데이터와 메시지를 지운다.
Breadcrumb? scrubBreadcrumb(Breadcrumb? b) {
  if (b == null) return null;
  final isHttp = b.type == 'http' || b.category == 'http' || b.category == 'xhr';
  b.data = null;
  if (isHttp) {
    b.message = null;
  } else if (b.message != null) {
    b.message = scrubText(b.message!);
  }
  return b;
}
