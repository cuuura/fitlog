// Play Integrity Android 구현(contracts/v1.0/security.md). 네이티브 쪽은 MainActivity.kt의 `fitlog/integrity` 채널.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'integrity.dart';

/// 클라우드 프로젝트 번호. 빌드 시 `--dart-define=PLAY_CLOUD_PROJECT_NUMBER=<숫자>`. 없으면 무결성 기능 꺼짐.
const playCloudProjectNumber = String.fromEnvironment('PLAY_CLOUD_PROJECT_NUMBER');

const integrityChannel = MethodChannel('fitlog/integrity');

bool get _runningOnAndroid => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// 무결성 기능을 쓸 수 있는 빌드/플랫폼인지(Android + 프로젝트 번호 있음).
bool get playIntegrityAvailable => playCloudProjectNumber.isNotEmpty && _runningOnAndroid;

/// Standard API 토큰 제공자는 첫 호출 때 한 번만 준비한다(실패하면 다음 호출에서 다시 시도).
/// 어떤 실패든(오류, 2초 초과, 번호 없음, Android 아님) null을 돌려주고 예외를 던지지 않는다.
class PlayIntegrityTokenSource implements IntegrityTokenSource {
  PlayIntegrityTokenSource({
    required this.cloudProjectNumber,
    this.channel = integrityChannel,
    this.timeout = const Duration(seconds: 2),
    bool? isAndroid,
  }) : _isAndroid = isAndroid ?? _runningOnAndroid;

  final String cloudProjectNumber;
  final Duration timeout;
  final MethodChannel channel;
  final bool _isAndroid;
  bool _prepared = false;

  @override
  Future<String?> token(String requestHash) async {
    if (!_isAndroid || cloudProjectNumber.isEmpty) return null;
    try {
      return await _fetch(requestHash).timeout(timeout);
    } catch (_) {
      return null;
    }
  }

  Future<String?> _fetch(String requestHash) async {
    if (!_prepared) {
      await channel.invokeMethod<bool>('prepare', {'cloudProjectNumber': cloudProjectNumber});
      _prepared = true;
    }
    final token = await channel.invokeMethod<String>('request', {'requestHash': requestHash});
    return (token == null || token.isEmpty) ? null : token;
  }
}
