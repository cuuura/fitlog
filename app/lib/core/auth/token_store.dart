import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 저장된 로그인 토큰.
class StoredTokens {
  final String accessToken;
  final String refreshToken;

  /// 액세스 토큰 만료 시각(UTC).
  final DateTime expiresAt;
  const StoredTokens({required this.accessToken, required this.refreshToken, required this.expiresAt});
}

/// 토큰 저장소. 실제 구현은 flutter_secure_storage, 테스트는 [MemoryTokenStore].
abstract interface class TokenStore {
  Future<StoredTokens?> read();
  Future<void> write(StoredTokens tokens);

  /// 토큰을 지운다. [keepUserId]가 true면 마지막 로그인 사용자 ID는 남긴다
  /// (세션 만료 후 다른 계정으로 로그인했을 때 로컬 데이터를 비우기 위해).
  Future<void> clear({bool keepUserId = false});

  /// 마지막으로 로그인한 사용자 ID.
  Future<String?> readUserId();
  Future<void> writeUserId(String id);
}

class SecureTokenStore implements TokenStore {
  static const _kAccess = 'auth.access';
  static const _kRefresh = 'auth.refresh';
  static const _kExpires = 'auth.expiresAt';
  static const _kUser = 'auth.userId';

  final FlutterSecureStorage _s;
  SecureTokenStore([FlutterSecureStorage? storage]) : _s = storage ?? const FlutterSecureStorage();

  @override
  Future<StoredTokens?> read() async {
    try {
      final a = await _s.read(key: _kAccess);
      final r = await _s.read(key: _kRefresh);
      final e = await _s.read(key: _kExpires);
      if (a == null || r == null) return null;
      return StoredTokens(
        accessToken: a,
        refreshToken: r,
        expiresAt: DateTime.tryParse(e ?? '')?.toUtc() ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(StoredTokens t) async {
    await _s.write(key: _kAccess, value: t.accessToken);
    await _s.write(key: _kRefresh, value: t.refreshToken);
    await _s.write(key: _kExpires, value: t.expiresAt.toUtc().toIso8601String());
  }

  @override
  Future<void> clear({bool keepUserId = false}) async {
    try {
      await _s.delete(key: _kAccess);
      await _s.delete(key: _kRefresh);
      await _s.delete(key: _kExpires);
      if (!keepUserId) await _s.delete(key: _kUser);
    } catch (_) {}
  }

  @override
  Future<String?> readUserId() async {
    try {
      return await _s.read(key: _kUser);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> writeUserId(String id) => _s.write(key: _kUser, value: id);
}

class MemoryTokenStore implements TokenStore {
  StoredTokens? tokens;
  String? userId;
  MemoryTokenStore({this.tokens, this.userId});

  @override
  Future<StoredTokens?> read() async => tokens;
  @override
  Future<void> write(StoredTokens t) async => tokens = t;
  @override
  Future<void> clear({bool keepUserId = false}) async {
    tokens = null;
    if (!keepUserId) userId = null;
  }

  @override
  Future<String?> readUserId() async => userId;
  @override
  Future<void> writeUserId(String id) async => userId = id;
}

final tokenStoreProvider = Provider<TokenStore>((ref) => SecureTokenStore());
