# fitlog 앱 (Flutter)

Android 우선, 이후 웹·iOS. 계약은 `../contracts/v0.1/`~`v1.0/`.

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

## 실기기 확인 절차 (클라우드에 Android SDK가 없어 사람이 폰에서 확인)

준비: Android Studio(또는 Android SDK + Flutter 3.50), USB 디버깅 켠 Android 폰, 서버 실행(`../server/README.md`), Google Cloud 콘솔의 OAuth 클라이언트 2개(Android: 패키지 `com.fitlog.fitlog` + 디버그 SHA-1, 웹: 서버 검증용 ID).

```bash
cd app
flutter run --dart-define=API_BASE_URL=http://<PC의 LAN IP>:8080 \
            --dart-define=GOOGLE_SERVER_CLIENT_ID=<웹 클라이언트 ID>
```

| # | 확인할 것 | 기대 결과 |
| --- | --- | --- |
| 1 | Google 로그인 → 동의 3개 체크 | 홈으로 이동. 재실행해도 로그인 유지 |
| 2 | 자유 세션 시작 → 종목 추가 → 세트 완료 | 휴식 타이머가 화면 하단과 **상단 알림·잠금화면**에 카운트다운 |
| 3 | 타이머 도는 중 홈 버튼으로 나가기 | 끝나는 시각에 소리·진동 알림 (늦으면 설정 → "휴식 종료 알림 정확하게 받기") |
| 4 | 비행기 모드로 세트 몇 개 기록 → 세션 종료 → 비행기 모드 해제 | 홈의 동기화 아이콘이 "대기" → 완료. 서버 DB에 세션이 남음 |
| 5 | 앱 강제 종료 후 다시 열기(세션 진행 중) | 홈에 "이어서 기록" |
| 6 | (v0.2) 프로그램 → 5x5 → 시작(TM 입력) → 홈 "오늘 할 운동" 시작 | 계획 무게로 세트가 미리 채워짐. 종료 후 요약에 다음 회차 무게 |
| 8 | (v0.3) 설정 → AI 연동 → 내보내기 → JSON 백업 | 공유 시트가 뜨고 파일이 첨부됨 |
| 9 | (v0.3) AI 연동 → AI 연결 → 주소 복사 → Claude/ChatGPT 커넥터에 추가·로그인 | 연결된 AI 목록에 나타남. AI가 삭제를 요청하면 홈에 배너 |
| 10 | (v0.3) 프롬프트 복사 → AI 답변 붙여넣기 → 미리보기 → 저장 | 세션에 "AI" 배지, 이력에서 되돌리기 가능 |
| 7 | 릴리스 빌드 `flutter build apk --obfuscate --split-debug-info=build/symbols` | 빌드 성공, 설치 후 1번 동작 |
| 11 | (v1.0) 기록 화면 → 추이 그래프 아이콘 → 기간·지표 바꾸기 → 점 탭 | 꺾은선과 PR 점(다른 색), 전체 최고 점선, 점 탭 시 날짜·무게×횟수와 "이 세션 보기" |
| 12 | (v1.0) 세션 종료 → 요약 → "지난 세션과 비교" | 종목별 막대(지난·오늘·이전 PR 색 구분), 세트별 표, 처음 하는 종목은 "첫 기록" |
| 13 | (v1.0) GitHub Actions `app` 워크플로의 릴리스 APK 설치(서명 시크릿·`API_BASE_URL` 설정 후) | 설치·로그인·동기화 정상(R8 난독화로 깨지는 기능 없음: 알림, 로그인, 가져오기, 내보내기) |
| 14 | (v1.0) 서버 `INTEGRITY_MODE=report`로 로그인 | 서버 로그에 무결성 판정이 남음. Play 내부 테스트 트랙 설치본이어야 PLAY_RECOGNIZED |
| 15 | (v1.0) `SENTRY_DSN` 넣은 빌드에서 일부러 오류(개발자 옵션 없이 어렵다면 생략) | Sentry에 이벤트가 오고 이메일·토큰이 가려져 있음. 설정에서 끄면 다음 실행부터 안 보냄 |
| 16 | (v1.0) 폰 글씨 크기 최대 + 다크 모드로 홈·세션·설정 | 글자 잘림·겹침 없음 |
| 17 | (v1.0) 설정 → 개인정보 처리방침 | 브라우저에서 `{API_BASE_URL}/privacy`가 열림 |
| 18 | (테스트용) 서버 `PASSWORD_LOGIN_ENABLED=true`, `PASSWORD_SIGNUP_CODE` 설정 → 로그인 화면 가입 → 로그아웃 → 아이디 로그인 | Google 없이 로그인·동의·기록 가능. 설정 계정 칸에 아이디 표시. 비밀번호 5번 틀리면 잠금 안내 |

v1.0 릴리스 준비(서명 키, Play Console, 스토어 자료, 사용자 결정 항목)는 `store/release-checklist.md`, 등록 문구는 `store/listing-ko.md`.
