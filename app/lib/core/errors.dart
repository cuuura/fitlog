// B3 소유. 새 화면이 쓰는 공용 오류 문구(계약 security.md: RATE_LIMITED는 "잠시 후 다시 시도", 자동 재시도 없음).
import '../l10n/gen/app_localizations.dart';
import 'api/api_client.dart';

enum ErrorKind { network, rateLimited, integrityFailed, other }

ErrorKind errorKindOf(Object error) {
  if (error is ApiException) {
    if (error.isNetwork) return ErrorKind.network;
    if (error.isRateLimited) return ErrorKind.rateLimited;
    if (error.code == 'INTEGRITY_FAILED') return ErrorKind.integrityFailed;
  }
  return ErrorKind.other;
}

/// 화면에 보여줄 한 줄. 서버 메시지는 쓰지 않는다.
String errorMessage(AppLocalizations l, Object error) => switch (errorKindOf(error)) {
  ErrorKind.network => l.errorNetwork,
  ErrorKind.rateLimited => l.errorRateLimited,
  ErrorKind.integrityFailed => l.errorIntegrityFailed,
  ErrorKind.other => l.errorGeneric,
};
