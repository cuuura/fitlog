# 무료 테스트 서버 (Render)

Render 무료 플랜(웹 서비스 + 무료 PostgreSQL)에 Blueprint(`render.yaml`) 한 번으로 테스트 서버를 띄운다. 운영용이 아니라 테스트용이다.

## 따라 하기

1. [render.com](https://render.com) 에 GitHub 계정으로 가입한다.
2. Dashboard → **New → Blueprint** → `cuuura/fitlog` 저장소를 연결·선택한다. `PASSWORD_SIGNUP_CODE`(가입 코드, 본인만 아는 값)를 입력하고 **Apply**. 첫 빌드는 5~10분 걸린다.
3. 서비스 주소(`https://fitlog-server-xxxx.onrender.com`)에 `/health/ready` 를 붙여 열어 정상인지 확인한다.
4. GitHub Actions → **app** → **Run workflow**(main)에서 `api_base_url` 칸에 그 주소(끝 슬래시 없음)를 넣고 실행한다. 매번 넣기 싫으면 Settings → Secrets and variables → Actions → **Variables** 에 `API_BASE_URL` 로 저장해 두면 main 푸시 때도 그 주소로 빌드된다.
5. 끝나면 `app-release` 아티팩트에서 APK를 받아 설치한다. 디버그 키로 서명되므로 Play 업로드는 못 하지만 테스트 설치는 된다.
6. 앱 로그인 화면에서 아이디로 가입(가입 코드 입력)한 뒤 사용한다.

로컬 빌드 대안:

```bash
cd app
flutter build apk --release --dart-define=API_BASE_URL=https://fitlog-server-xxxx.onrender.com
flutter run --dart-define=API_BASE_URL=https://fitlog-server-xxxx.onrender.com
```

`main` 에 푸시하면 Render 가 자동으로 재배포한다(`autoDeploy`).

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
- MCP 연결: [mcp-connect.md](mcp-connect.md). `PUBLIC_BASE_URL` 은 Render 주소(`RENDER_EXTERNAL_URL`)가 자동으로 쓰인다.

## 출시 전

테스트용 아이디·비밀번호 로그인은 출시 전에 `PASSWORD_LOGIN_ENABLED` 를 꺼야 한다.
