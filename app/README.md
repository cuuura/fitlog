# fitlog 앱 (Flutter)

Android 우선, 이후 웹·iOS. 계약은 `../contracts/v0.1/`.

## 실행

```bash
flutter pub get        # gen-l10n도 같이 돈다 (lib/l10n/gen)
flutter analyze
flutter test
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8080 \
            --dart-define=GOOGLE_SERVER_CLIENT_ID=<웹 클라이언트 ID>.apps.googleusercontent.com
# 릴리스(복제 방지): flutter build apk --obfuscate --split-debug-info=build/symbols
```

## 구조와 소유

| 경로 | 소유 | 내용 |
| --- | --- | --- |
| `lib/core/api/` `lib/core/ids.dart` `lib/core/units.dart` `lib/core/clock.dart` `lib/core/routes.dart` `lib/domain/` `lib/data/memory/` `lib/data/providers.dart` | 트랙 리드 | DTO·API 클라이언트, WP 사이 인터페이스, 메모리 구현 |
| `lib/core/auth/` `lib/core/settings/` `lib/core/router.dart` `lib/core/theme.dart` `lib/features/auth/` `settings/` `profile/` | B1 | 로그인·동의·설정·프로필·체중 |
| `lib/features/home/` `session/` `exercise_picker/` | B2 | 홈, 자유 세션 기록, 종목 선택 |
| `lib/features/rest_timer/` `lib/data/local/` `lib/data/sync/` | B3 | 휴식 타이머·알림·화면 꺼짐 방지, drift DB, outbox 동기화 |

## 규칙

- Material은 `package:material_ui/material_ui.dart`를 쓴다(Flutter 3.50에서 `flutter/material.dart`는 deprecated).
- 상태 관리는 Riverpod 3(`Notifier`, `Provider`), 코드 생성(riverpod_generator, freezed, json_serializable)은 쓰지 않는다. drift만 build_runner를 쓰고 `*.g.dart`는 커밋한다.
- 화면은 `lib/domain/repositories.dart` 인터페이스만 쓰고, Provider는 `lib/data/providers.dart`에서 읽는다.
- 무게는 내부에서 항상 kg. 표시·입력 변환은 `Units`.
- ID는 `newId()`(UUIDv7). 시각은 UTC로 다루고 표시할 때만 로컬로.
- 화면 문구는 `lib/l10n/app_ko.arb`(기본)와 `app_en.arb`에 넣는다. 키 앞에 기능 이름을 붙인다(`session…`, `settings…`).
- 다른 WP 소유 파일이나 계약을 바꿔야 하면 바꾸지 말고 보고한다.
