import 'package:fitlog/core/api/api_client.dart';
import 'package:fitlog/core/crash/crash_reporting.dart';
import 'package:fitlog/core/crash/pii_scrubber.dart';
import 'package:fitlog/core/errors.dart';
import 'package:fitlog/l10n/gen/app_localizations_ko.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('scrubText', () {
    test('이메일·Bearer·JWT·token=값·긴 토큰을 가린다', () {
      expect(scrubText('user a.b+c@example.com failed'), 'user [email] failed');
      expect(scrubText('Authorization: Bearer abc.def-ghi'), isNot(contains('abc')));
      expect(scrubText('jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.sig_nature ok'), 'jwt [token] ok');
      expect(scrubText('refresh_token=abcd1234 next'), 'refresh_token=[token] next');
      expect(scrubText('{"accessToken": "zzz999"}'), contains('[token]'));
      expect(scrubText('id 0123456789abcdef0123456789abcdef0123'), 'id [token]');
    });

    test('평범한 문장은 그대로 둔다', () {
      expect(scrubText('RangeError (index): Invalid value: 3'), 'RangeError (index): Invalid value: 3');
    });
  });

  group('scrubEvent', () {
    test('user·request·extra 제거, 예외·메시지 가림, http 이력 정리', () {
      final event = SentryEvent(
        user: SentryUser(id: '1', email: 'me@example.com', ipAddress: '1.2.3.4'),
        request: SentryRequest(
          url: 'https://x/v1/sessions',
          data: {'weight': 100},
          headers: {'authorization': 'Bearer x'},
        ),
        message: SentryMessage('login me@example.com'),
        exceptions: [SentryException(type: 'StateError', value: 'bad token=abc123 for me@example.com')],
        breadcrumbs: [
          Breadcrumb(type: 'http', category: 'http', message: 'GET https://x/v1/sessions/1', data: {'url': 'u'}),
          Breadcrumb(message: 'tap me@example.com', data: {'k': 'v'}),
        ],
      );
      final out = scrubEvent(event);
      expect(out.user, isNull);
      expect(out.request, isNull);
      expect(out.message!.formatted, 'login [email]');
      expect(out.exceptions!.single.value, 'bad token=[token] for [email]');
      expect(out.breadcrumbs!.length, 2);
      expect(out.breadcrumbs![0].data, isNull);
      expect(out.breadcrumbs![0].message, isNull);
      expect(out.breadcrumbs![1].data, isNull);
      expect(out.breadcrumbs![1].message, 'tap [email]');
    });

    test('scrubBreadcrumb(null)은 null', () => expect(scrubBreadcrumb(null), isNull));
  });

  test('configureSentry: PII 끔, 훅 연결', () {
    final o = SentryFlutterOptions();
    configureSentry(o);
    expect(o.sendDefaultPii, isFalse);
    expect(o.attachScreenshot, isFalse);
    expect(o.beforeSend, isNotNull);
    expect(o.beforeBreadcrumb, isNotNull);
  });

  group('runWithCrashReporting', () {
    test('DSN이 없으면 Sentry 없이 appRunner만 실행', () async {
      var ran = 0;
      var asked = 0;
      await runWithCrashReporting(
        () => ran++,
        dsn: '',
        isEnabled: () async {
          asked++;
          return true;
        },
      );
      expect(ran, 1);
      expect(asked, 0);
      expect(Sentry.isEnabled, isFalse);
    });

    test('토글이 꺼져 있으면 DSN이 있어도 초기화하지 않는다', () async {
      var ran = 0;
      await runWithCrashReporting(() => ran++, dsn: 'https://k@example.invalid/1', isEnabled: () async => false);
      expect(ran, 1);
      expect(Sentry.isEnabled, isFalse);
    });
  });

  group('토글 저장', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('기본 켬, 저장하면 다음에도 유지', () async {
      expect(await loadCrashReportingEnabled(), isTrue);
      final c = ProviderContainer();
      addTearDown(c.dispose);
      await c.read(crashReportingEnabledProvider.notifier).set(false);
      expect(c.read(crashReportingEnabledProvider), isFalse);
      expect(await loadCrashReportingEnabled(), isFalse);
    });

    test('DSN 상수가 없으면 사용 불가(토글 숨김)', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      expect(c.read(crashReportingAvailableProvider), CrashConfig.dsn.isNotEmpty);
    });
  });

  group('errorMessage', () {
    final l = AppLocalizationsKo();
    test('NETWORK / RATE_LIMITED / INTEGRITY_FAILED / 기타', () {
      expect(errorMessage(l, const ApiException(code: 'NETWORK', message: 'x')), l.errorNetwork);
      expect(
        errorMessage(l, const ApiException(statusCode: 429, code: 'RATE_LIMITED', message: 'x')),
        l.errorRateLimited,
      );
      expect(errorMessage(l, const ApiException(statusCode: 429, code: 'HTTP_429', message: 'x')), l.errorRateLimited);
      expect(
        errorMessage(l, const ApiException(statusCode: 403, code: 'INTEGRITY_FAILED', message: 'x')),
        l.errorIntegrityFailed,
      );
      expect(errorMessage(l, const ApiException(statusCode: 500, code: 'INTERNAL', message: 'secret')), l.errorGeneric);
      expect(errorMessage(l, StateError('boom')), l.errorGeneric);
    });
  });
}
