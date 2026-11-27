# 테스트 빌드 전용 서명 키

`fitlog-test.keystore`(비밀번호·별칭 `fitlogtest`)는 **테스트 APK 전용**이며, 사용자 결정(2026-11-27)으로 일부러 커밋했다.
CI 러너마다 디버그 키가 새로 만들어지면 빌드마다 서명이 달라져 폰에서 덮어 설치가 안 되기 때문이다(「앱이 설치되지 않음」).

- 릴리스 서명 시크릿(`ANDROID_KEYSTORE_BASE64` 등)이나 `key.properties` 가 있으면 그 키가 우선이고 이 키는 쓰지 않는다.
- 공개된 키이므로 Play 업로드·실사용자 배포에는 절대 쓰지 않는다. Play 업로드 키는 시크릿으로만 보관한다(app/store/release-checklist.md).
