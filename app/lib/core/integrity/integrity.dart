// Play Integrity 경계(contracts/v1.0/security.md). 인터페이스·해시는 트랙 리드, Android 구현은 B2.
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'play_integrity.dart';

/// 인증 요청 직전에 무결성 토큰을 얻는다. 못 얻으면 null(헤더 없이 보낸다). 예외를 던지지 않는다.
abstract interface class IntegrityTokenSource {
  Future<String?> token(String requestHash);
}

class NoIntegrity implements IntegrityTokenSource {
  const NoIntegrity();
  @override
  Future<String?> token(String requestHash) async => null;
}

/// 요청 본문의 토큰 값을 UTF-8 SHA-256 → base64url(패딩 없음).
String integrityRequestHash(String value) =>
    base64Url.encode(sha256.convert(utf8.encode(value)).bytes).replaceAll('=', '');

const integrityHeader = 'X-Integrity-Token';

/// B2가 Android 구현으로 바꾼다. 테스트·웹은 NoIntegrity.
final integrityTokenSourceProvider = Provider<IntegrityTokenSource>(
  (ref) => playIntegrityAvailable
      ? PlayIntegrityTokenSource(cloudProjectNumber: playCloudProjectNumber)
      : const NoIntegrity(),
);
