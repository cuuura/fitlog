# fitlog v1.0 릴리스 체크리스트

`{BASE_URL}`은 서버 공개 주소(앱 빌드의 `API_BASE_URL`과 같다).

## 0. 먼저 사용자가 정할 것 (코드로 못 정한다)

- [ ] **applicationId** — 지금 `com.fitlog.fitlog`. **첫 Play 업로드 후에는 바꿀 수 없다.** 도메인을 가진 이름으로 바꿀 거면 업로드 전에 `app/android/app/build.gradle.kts`(`namespace`, `applicationId`), `MainActivity.kt` 패키지 경로, Google Cloud Android OAuth 클라이언트, `proguard-rules.pro`의 `com.fitlog.fitlog` 규칙을 같이 바꾼다
- [ ] **CONTACT_EMAIL** — 처리방침·스토어 등록정보의 문의 이메일
- [ ] **EFFECTIVE_DATE** — 처리방침 시행일(`YYYY-MM-DD`). 방침을 바꾸면 시행 7일 전 공지
- [ ] **BACKUP_RETENTION_DAYS** — 계정 삭제 후 백업에 남는 최대 일수(실제 백업 정책과 같아야 한다)
- [ ] **Play Console 개발자 계정** — 개인/조직 선택, 등록비 US$25, 본인 확인. 개인 계정은 신규 앱이 프로덕션 전에 비공개 테스트(12명 이상, 14일 이상) 요건이 있을 수 있으니 계정 유형별 최신 요건을 Console에서 확인
- [ ] **서버 공개 주소(BASE_URL)** 와 HTTPS 인증서
- [ ] 심사용 Google 테스트 계정

## 1. 서버·Google Cloud 준비

- [ ] 서버가 `{BASE_URL}/privacy`, `{BASE_URL}/account-deletion`을 공개로 서빙(로그인 없이 열림)
- [ ] 처리방침 `{{…}}` 자리표시자 4개(EFFECTIVE_DATE, CONTACT_EMAIL, BACKUP_RETENTION_DAYS, BASE_URL)가 모두 채워짐
- [ ] Google Cloud 프로젝트에서 OAuth 클라이언트: 웹(서버 검증용 → `GOOGLE_SERVER_CLIENT_ID`), Android(패키지명 + **Play 앱 서명 SHA-1**, 업로드 키 SHA-1, 디버그 SHA-1 각각 등록)
- [ ] Google Cloud 프로젝트에서 Play Integrity API 사용 설정, 프로젝트 번호 확인(→ `PLAY_CLOUD_PROJECT_NUMBER`)
- [ ] 서버 서비스 계정에 Integrity 토큰 해석 권한, 서버 `INTEGRITY_MODE` 설정(처음에는 `report`로 로그만 보고, 정상 확인 뒤 `enforce`)

## 2. GitHub Actions 값 (`.github/workflows/app.yml`)

Variables(또는 Secrets):
- [ ] `API_BASE_URL` — 없으면 main 푸시의 릴리스 빌드는 컴파일 확인만 하고 산출물(AAB·APK)을 올리지 않는다
- [ ] `GOOGLE_SERVER_CLIENT_ID`
- [ ] `PLAY_CLOUD_PROJECT_NUMBER` (비우면 무결성 꺼짐)
- [ ] `SENTRY_DSN` (비우면 오류 보고 꺼짐)

Secrets(업로드 키 서명, 4개가 모두 있어야 서명한다. 없으면 디버그 키로 빌드되어 Play에 올릴 수 없다):
- [ ] `ANDROID_KEYSTORE_BASE64` — `base64 -w0 upload.jks`
- [ ] `ANDROID_KEYSTORE_PASSWORD`
- [ ] `ANDROID_KEY_ALIAS`
- [ ] `ANDROID_KEY_PASSWORD`

업로드 키 만들기(한 번만, 안전한 곳에 백업. 잃으면 Play 지원을 통해 재설정해야 한다):
```bash
keytool -genkeypair -v -keystore upload.jks -alias upload -keyalg RSA -keysize 2048 -validity 10000
```
로컬 릴리스 빌드는 `app/android/key.properties`(gitignore됨)에 `storeFile`, `storePassword`, `keyAlias`, `keyPassword`를 적는다. 없으면 디버그 키로 폴백.

## 3. 첫 CI 실행에서 확인 (로컬에서 검증 못 한 것)

- [ ] PR의 `flutter build apk --debug`가 통과(Kotlin `MainActivity.kt`, `com.google.android.play:integrity:1.4.0`, `build.gradle.kts` 서명 설정 컴파일)
- [ ] main 푸시의 `flutter build appbundle --release --obfuscate`가 통과(R8: `proguard-rules.pro`가 누락 클래스 오류 없이 처리). 실패하면 로그의 "Missing class" 항목을 `-dontwarn`/`-keep`에 추가
- [ ] 산출물 `app-release`(aab, apk), `app-symbols` 업로드됨. **symbols는 릴리스마다 보관**(난독화된 크래시 복원용)
- [ ] 릴리스 APK를 실기기에 설치해 로그인·기록·동기화·휴식 알림이 되는지(R8이 플러그인을 깨뜨리지 않았는지, INTERNET 권한 포함)

## 4. Play Console 순서

1. [ ] **앱 만들기**: 이름 "fitlog - 운동 기록", 기본 언어 한국어, 앱, 무료
2. [ ] **앱 서명**: Play App Signing 사용(기본). 첫 aab를 올릴 때 업로드 키로 서명된 것을 올리면 Google이 앱 서명 키를 보관
3. [ ] **스토어 등록정보**: `app/store/listing-ko.md`의 이름·짧은/자세한 설명·스크린샷·아이콘 512x512·그래픽 1024x500
4. [ ] **앱 콘텐츠**:
   - [ ] 개인정보처리방침 URL = `{BASE_URL}/privacy`
   - [ ] 계정 삭제 URL = `{BASE_URL}/account-deletion` (앱 안 삭제 경로 + 웹 경로 모두)
   - [ ] 데이터 보안 양식 = `listing-ko.md`의 표대로
   - [ ] 콘텐츠 등급 설문, 타깃 연령(14세 이상), 광고 없음, 건강 앱 선언, 앱 액세스(테스트 계정)
5. [ ] **타깃 API 수준**: Play는 신규 앱·업데이트에 최신 요구 수준을 강제한다. 현재 `targetSdk`는 Flutter 3.50.1 기본값(`flutter.targetSdkVersion`). 업로드 때 Console이 요구 수준을 알려주므로 부족하면 Flutter를 올리거나 `targetSdk`를 명시
6. [ ] **내부 테스트 트랙**: aab 업로드 → 테스터(본인 계정) 등록 → 설치 링크로 설치
7. [ ] **Play Integrity 연결**: Play Console > 앱 무결성 > "Play Integrity API" → Google Cloud 프로젝트를 연결(1단계의 프로젝트). 연결 전에는 판정이 `UNRECOGNIZED_VERSION`이 될 수 있다
8. [ ] 내부 테스트 설치본으로 로그인 → 서버 로그(`INTEGRITY_MODE=report`)에서 `PLAY_RECOGNIZED`와 `MEETS_DEVICE_INTEGRITY` 확인 → 문제 없으면 `enforce`
9. [ ] 비공개/공개 테스트(계정 유형별 요건 확인) → 프로덕션 출시, 단계적 출시 비율 설정
10. [ ] 출시 후: Sentry에 난독화 매핑(`app-symbols`) 업로드, Play Console의 Android vitals 확인

## 5. 출시 전 마지막 확인

- [ ] 버전: `app/pubspec.yaml`의 `version: x.y.z+N` — `N`(versionCode)은 업로드마다 올라야 한다
- [ ] 릴리스 빌드에서 `API_BASE_URL`이 `http://10.0.2.2:8080`(개발 기본값)이 아님
- [ ] 설정 화면에 "개인정보 처리방침" 항목이 있고 `{BASE_URL}/privacy`가 열림
- [ ] 처리방침과 데이터 보안 양식의 항목이 일치(`app/store/listing-ko.md`)
