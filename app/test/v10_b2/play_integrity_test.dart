import 'dart:async';

import 'package:fitlog/core/integrity/play_integrity.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/integrity');
  final calls = <MethodCall>[];

  void mock(Future<Object?> Function(MethodCall) h) {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (c) {
      calls.add(c);
      return h(c);
    });
  }

  PlayIntegrityTokenSource source({String number = '123', bool android = true, Duration? timeout}) =>
      PlayIntegrityTokenSource(
        cloudProjectNumber: number,
        channel: channel,
        isAndroid: android,
        timeout: timeout ?? const Duration(seconds: 2),
      );

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('성공: prepare는 한 번만, request마다 토큰', () async {
    mock((c) async => c.method == 'prepare' ? true : 'tok-${(c.arguments as Map)['requestHash']}');
    final s = source();
    expect(await s.token('h1'), 'tok-h1');
    expect(await s.token('h2'), 'tok-h2');
    expect(calls.map((c) => c.method), ['prepare', 'request', 'request']);
    expect(calls.first.arguments, {'cloudProjectNumber': '123'});
  });

  test('프로젝트 번호 없음 / Android 아님: 채널을 부르지 않고 null', () async {
    mock((c) async => 'x');
    expect(await source(number: '').token('h'), isNull);
    expect(await source(android: false).token('h'), isNull);
    expect(calls, isEmpty);
  });

  test('예외는 null이고 다음 호출에서 prepare를 다시 시도', () async {
    var fail = true;
    mock((c) async {
      if (c.method == 'prepare' && fail) throw PlatformException(code: 'PREPARE_FAILED');
      return c.method == 'prepare' ? true : 'tok';
    });
    final s = source();
    expect(await s.token('h'), isNull);
    fail = false;
    expect(await s.token('h'), 'tok');
    expect(calls.where((c) => c.method == 'prepare').length, 2);
  });

  test('request 오류는 null, prepare는 다시 하지 않음', () async {
    var fail = true;
    mock((c) async {
      if (c.method == 'request' && fail) throw PlatformException(code: 'REQUEST_FAILED');
      return c.method == 'prepare' ? true : 'tok';
    });
    final s = source();
    expect(await s.token('h'), isNull);
    fail = false;
    expect(await s.token('h'), 'tok');
    expect(calls.where((c) => c.method == 'prepare').length, 1);
  });

  test('시간 초과는 null', () async {
    final never = Completer<Object?>();
    mock((c) => never.future);
    expect(await source(timeout: const Duration(milliseconds: 50)).token('h'), isNull);
  });

  test('빈 토큰은 null', () async {
    mock((c) async => c.method == 'prepare' ? true : '');
    expect(await source().token('h'), isNull);
  });

  test('테스트 환경에서는 무결성 기능이 꺼져 있다', () {
    expect(playIntegrityAvailable, isFalse);
  });
}
