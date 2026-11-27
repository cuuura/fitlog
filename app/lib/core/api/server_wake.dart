// 무료 호스팅 서버는 한동안 안 쓰면 잠들고, 깨는 데 1분 가까이 걸린다(Render free tier).
// 그동안 요청이 20초 만에 끊기면 로그인 수단이 안 보이거나 화면이 오류로 끝난다.
// - 서버가 깨어 있다고 확인되기 전(앱 시작 직후, 10분 이상 조용했을 때)의 첫 요청은 타임아웃을 길게 잡는다.
// - 연결 오류·게이트웨이 오류(502/503/504)는 지수 백오프로 몇 번 다시 시도한다.
// - 첫 요청이 오래 걸리면 [ServerWake.waking]을 켜서 화면이 "서버 깨우는 중"을 알린다.
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 서버가 깨어 있는지 추적한다. 응답을 한 번이라도 받으면(오류 응답이어도, 게이트웨이 오류만 빼고) 깨어 있는 것.
class ServerWake {
  ServerWake({
    DateTime Function()? now,
    this.sleepAfter = const Duration(minutes: 10),
    this.showAfter = const Duration(seconds: 5),
  }) : _now = now ?? DateTime.now;

  final DateTime Function() _now;

  /// 이 시간 동안 응답이 없었으면 서버가 다시 잠들었을 수 있다고 본다(Render는 15분).
  final Duration sleepAfter;

  /// 콜드 요청이 이만큼 걸리면 "깨우는 중" 표시를 켠다.
  final Duration showAfter;

  DateTime? _lastResponse;
  final Set<Object> _coldInFlight = {};
  Timer? _timer;

  /// 화면에 "서버 깨우는 중"을 보일지.
  final ValueNotifier<bool> waking = ValueNotifier(false);

  bool get isCold {
    final last = _lastResponse;
    return last == null || _now().difference(last) > sleepAfter;
  }

  void begin(Object token) {
    _coldInFlight.add(token);
    _timer ??= Timer(showAfter, () {
      if (_coldInFlight.isNotEmpty) waking.value = true;
    });
  }

  void end(Object token) {
    _coldInFlight.remove(token);
    if (_coldInFlight.isEmpty) {
      _timer?.cancel();
      _timer = null;
      waking.value = false;
    }
  }

  void markAwake() => _lastResponse = _now();

  void dispose() {
    _timer?.cancel();
    waking.dispose();
  }
}

final serverWakeProvider = Provider<ServerWake>((ref) {
  final w = ServerWake();
  ref.onDispose(w.dispose);
  return w;
});

/// 콜드 스타트 대응 인터셉터. 인증 인터셉터보다 앞에 둔다.
class WakeRetryInterceptor extends Interceptor {
  WakeRetryInterceptor({
    required this.dio,
    required this.wake,
    this.coldTimeout = const Duration(seconds: 75),
    this.coldDelays = const [Duration(seconds: 2), Duration(seconds: 4), Duration(seconds: 8), Duration(seconds: 15)],
    this.warmDelays = const [Duration(seconds: 1), Duration(seconds: 3)],
    this.connectionErrorDelays = const [Duration(seconds: 1)],
  });

  final Dio dio;
  final ServerWake wake;
  final Duration coldTimeout;
  final List<Duration> coldDelays;
  final List<Duration> warmDelays;
  final List<Duration> connectionErrorDelays;

  static const _kCold = 'wake.cold';
  static const _kAttempt = 'wake.attempt';
  static const _kToken = 'wake.token';

  /// 재시도해도 같은 토큰이라 "깨우는 중" 표시가 재시도 사이에 꺼지지 않는다.
  static Object _token(RequestOptions o) => o.extra[_kToken] ??= Object();

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (wake.isCold) {
      options.extra[_kCold] = true;
      options.connectTimeout = _max(options.connectTimeout, coldTimeout);
      options.receiveTimeout = _max(options.receiveTimeout, coldTimeout);
      wake.begin(_token(options));
    }
    handler.next(options);
  }

  static Duration _max(Duration? a, Duration b) => a == null || a < b ? b : a;

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    wake.markAwake();
    wake.end(_token(response.requestOptions));
    handler.next(response);
  }

  /// 서버가 아직 안 떴을 때 프록시가 돌려주는 상태.
  static bool isGatewayDown(int? status) => status == 502 || status == 503 || status == 504;

  /// 같은 요청을 다시 보내도 되는가. 멱등하지 않은 요청(POST·PATCH)은 서버에 닿지 않았음이 확실할 때만.
  static bool retryable(DioException e) {
    final method = e.requestOptions.method.toUpperCase();
    final safe = method == 'GET' || method == 'HEAD' || method == 'PUT' || method == 'DELETE';
    final status = e.response?.statusCode;
    if (e.response != null) {
      if (status == 504) return safe;
      return status == 502 || status == 503;
    }
    return switch (e.type) {
      DioExceptionType.connectionError || DioExceptionType.connectionTimeout => true,
      DioExceptionType.sendTimeout || DioExceptionType.receiveTimeout => safe,
      _ => false,
    };
  }

  @override
  Future<void> onError(DioException err, ErrorInterceptorHandler handler) async {
    final req = err.requestOptions;
    final res = err.response;
    if (res != null && !isGatewayDown(res.statusCode)) {
      wake.markAwake(); // 앱이 응답한 4xx/5xx: 깨어 있다
      wake.end(_token(req));
      return handler.next(err);
    }
    final cold = req.extra[_kCold] == true;
    // 연결 자체가 안 되는 경우(DNS 실패·연결 거부 = 대개 기기가 오프라인)는 오래 붙잡지 않고 한 번만 다시 해 본다.
    final delays = err.type == DioExceptionType.connectionError
        ? connectionErrorDelays
        : (cold ? coldDelays : warmDelays);
    final attempt = (req.extra[_kAttempt] as int?) ?? 0;
    if (!retryable(err) || attempt >= delays.length) {
      wake.end(_token(req));
      return handler.next(err);
    }
    await Future<void>.delayed(delays[attempt]);
    final next = req.copyWith(extra: {...req.extra, _kAttempt: attempt + 1});
    try {
      handler.resolve(await dio.fetch<dynamic>(next));
    } on DioException catch (e) {
      handler.next(e);
    }
  }
}

/// 앱 전체가 쓰는 Dio. 타임아웃은 평소 값이고, 콜드 스타트 때만 [WakeRetryInterceptor]가 늘린다.
Dio createApiDio({required String baseUrl, required ServerWake wake, HttpClientAdapter? adapter}) {
  final dio = Dio(
    BaseOptions(
      baseUrl: baseUrl,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 20),
      contentType: 'application/json',
    ),
  );
  if (adapter != null) dio.httpClientAdapter = adapter;
  dio.interceptors.add(WakeRetryInterceptor(dio: dio, wake: wake));
  return dio;
}
