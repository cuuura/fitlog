# 무료 테스트 서버 (Render)

Render 무료 플랜(웹 서비스 + 무료 PostgreSQL)에 Blueprint(`render.yaml`) 한 번으로 테스트 서버를 띄운다. 운영용이 아니라 테스트용이다.

## 따라 하기

1. [render.com](https://render.com) 에 GitHub 계정으로 가입한다.
2. Dashboard → **New → Blueprint** → `cuuura/fitlog` 저장소를 연결·선택한다. `PASSWORD_SIGNUP_CODE`(가입 코드, 본인만 아는 값)를 입력하고 **Apply**. 첫 빌드는 5~10분 걸린다.
3. 서비스 주소(`https://fitlog-server-xxxx.onrender.com`)에 `/health/ready` 를 붙여 열어 정상인지 확인한다.
4. GitHub Actions → **app** → **Run workflow**(main)에서 `api_base_url` 칸에 그 주소(끝 슬래시 없음)를 넣고 실행한다. 매번 넣기 싫으면 Settings → Secrets and variables → Actions → **Variables** 에 `API_BASE_URL` 로 저장해 두면 main 푸시 때도 그 주소로 빌드된다.
5. 끝나면 APK가 고정 링크 https://github.com/cuuura/fitlog/releases/download/test-build/fitlog-test.apk 로 올라간다(main 푸시 때마다 덮어씀). 폰에서 이 링크를 누르면 바로 받아 설치된다. 또는 `app-release` 아티팩트에서 APK를 받아 설치한다. 저장소의 고정 테스트 키(app/android/test-signing)로 서명돼 빌드가 바뀌어도 덮어 설치된다. Play 업로드는 못 한다.
6. 앱 로그인 화면에서 아이디로 가입(가입 코드 입력)한 뒤 사용한다.

로컬 빌드 대안:

```bash
cd app
flutter build apk --release --dart-define=API_BASE_URL=https://fitlog-server-xxxx.onrender.com
flutter run --dart-define=API_BASE_URL=https://fitlog-server-xxxx.onrender.com
```

`main` 에 푸시하면 Render 가 자동으로 재배포한다(`autoDeploy`). Render 는 서버를 직접 컴파일하지 않고 GitHub Actions 가 올린 이미지(ghcr.io/cuuura/fitlog-server:latest)를 받는다(server/Dockerfile). 푸시 직후 자동 배포는 이전 이미지를 받으므로, Render Settings > Deploy Hook 주소를 저장소 시크릿 `RENDER_DEPLOY_HOOK_URL` 로 넣어 두면 이미지 빌드 뒤 최신으로 다시 배포된다.

## 무료 플랜 제약

- 15분간 요청이 없으면 서비스가 잠들고, 다음 첫 요청에 약 1분 걸린다. 앱 첫 요청이 시간 초과되면 브라우저로 `/health/ready` 를 먼저 열어 깨운다.
  - 잠들지 않게: `.github/workflows/keep-awake.yml` 이 5분마다 `/health/ready` 를 호출한다(주소는 Variables `KEEP_AWAKE_URL`, 없으면 파일의 기본값). GitHub 스케줄은 늦거나 빠질 수 있으니 더 확실히 하려면 UptimeRobot 무료 모니터(HTTP, 5분 간격)로 같은 주소를 등록한다.
  - 무료 인스턴스 시간은 월 750시간이라 서비스 1개를 24시간 켜 두는 것(최대 744시간)은 한도 안이다. 무료 웹 서비스를 더 만들면 넘는다.
- 무료 PostgreSQL 은 생성 30일 뒤 만료되고 14일 유예 후 삭제된다. 그 전에 유료로 전환하거나 DB를 새로 만들어 연결한다.
- 저장 공간은 1GB, 백업은 없다.

## DB 만료 시 새 DB 연결

- 새 무료 DB를 만든 뒤 서비스 Environment 의 `DATABASE_URL` 을 그 **Internal Database URL** 로 교체한다.
- 다른 무료 DB(Neon 등)를 쓰려면 `DATABASE_URL` 에 그 연결 문자열(`sslmode=require` 포함)을 넣는다.

## 선택 설정

- Google 로그인: 서비스 Environment 에 `GOOGLE_CLIENT_IDS` 를 추가한다.
- MCP 연결: [mcp-connect.md](mcp-connect.md#테스트-서버아이디비밀번호로-연결) (아이디·비밀번호 계정으로도 연결된다). `PUBLIC_BASE_URL` 은 Render 주소(`RENDER_EXTERNAL_URL`)가 자동으로 쓰인다.

## 출시 전

테스트용 아이디·비밀번호 로그인은 출시 전에 `PASSWORD_LOGIN_ENABLED` 를 꺼야 한다.

배포된 버전 확인: `GET /health/version` 은 이미지를 빌드한 커밋 SHA 를 돌려준다. keep-awake 워크플로 로그에도 찍힌다. main 최신 커밋과 다르면 Render 가 이전 이미지를 받은 것이니, 이미지 빌드(server-image)가 끝난 뒤 Render 에서 Manual Deploy 를 하거나 RENDER_DEPLOY_HOOK_URL 시크릿을 넣어 둔다.
