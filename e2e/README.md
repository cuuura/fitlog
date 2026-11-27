# Fitlog E2E (블랙박스)

실제로 떠 있는 서버 프로세스에 진짜 HTTP 로 접속해서 앱과 ChatGPT/Claude(원격 MCP + OAuth 2.1)가 하는 요청을 그대로 재현한다. 서버 안에서 도는 `testApplication` 단위 테스트가 놓치는 문제(OAuth 로그인 방식, 동적 클라이언트 등록 페이로드, 재시작 뒤 MCP 세션, 앱·서버 동의 버전 불일치 등)를 잡는 것이 목적이다. Python 3 표준 라이브러리만 쓴다(pip 불필요).

## 실행

```bash
# 로컬 전체(빌드 → 서버 시작 → 점검 → 서버 재시작 → 점검). PostgreSQL 필요
e2e/run_local.sh

# 이미 떠 있는 서버에 직접
python3 e2e/run.py --base-url http://localhost:8080 --phase before-restart --signup-code <PASSWORD_SIGNUP_CODE>
#   (서버 재시작)
python3 e2e/run.py --base-url http://localhost:8080 --phase after-restart

# 재시작 없이 한 번에(배포 서버 점검용, 끝나면 만든 계정 삭제)
python3 e2e/run.py --base-url https://<서버> --phase all --cleanup --signup-code <코드>
```

`run_local.sh` 환경 변수: `E2E_PORT`(18080), `PG_HOST/PG_PORT/PG_USER/PG_PASSWORD`(localhost:5432 fitlog/fitlog), `E2E_DB`(fitlog_e2e, 매번 지우고 새로 만듦), `SKIP_BUILD=1`.

`before-restart` 는 재시작 뒤에 쓸 토큰·MCP 세션 ID 등을 `--state`(기본 `e2e/.state.json`)에 저장하고, `after-restart` 가 그 값을 그대로 써서 "재시작해도 살아있는가"를 확인한다. 하나라도 실패하면 종료 코드 1.

## 점검 범위

- 헬스, OAuth 메타데이터(+경로 접미사 변형), `openid-configuration` 탐색, `/mcp` 401 + `resource_metadata`
- 프록시 흉내: `X-Forwarded-*`/`Host` 를 바꿔 보내도 메타데이터 URL 이 `PUBLIC_BASE_URL` 로 나오는지
- 비밀번호 가입·로그인·잠금·토큰 회전, 앱과 같은 순서의 동의(앱의 `consentVersion` 을 읽어 서버가 인정하는지)
- 앱 REST 흐름: 프로그램 시작 → 계획 → 세션 저장 → 진행 반영 → sync push/pull → 기록·추이
- ChatGPT/Claude 식 동적 등록, PKCE S256 인가, 로그인·동의 폼 제출, 토큰 교환(post/basic/none), 리프레시 회전·재사용 감지
- MCP: initialize(2025-06-18, 2025-03-26), tools/list 정확한 도구 목록, **모든 도구를 유효한 인자로 호출**, 잘못된 인자 처리, 읽기 전용 연결 권한
- 재시작 뒤: 같은 액세스 토큰 + 같은 `Mcp-Session-Id` 로 tools/list·도구 호출, 리프레시, 앱 토큰, 등록된 OAuth 클라이언트

## MCP 도구를 추가·삭제할 때 (중요)

`e2e/run.py` 는 도구 목록을 한곳(`EXPECTED_READ_TOOLS` / `EXPECTED_WRITE_TOOLS`)에 가지고 있고, 서버 소스(`server/src/main/kotlin/com/fitlog/mcp/`)의 도구 이름과도 대조한다. **새 MCP 도구를 만들면 e2e 에 호출 사례를 함께 추가해야 하며, 빠뜨리면 E2E 가 실패한다.**

1. `EXPECTED_READ_TOOLS` 또는 `EXPECTED_WRITE_TOOLS` 에 이름 추가
2. `build_call_cases()` 에 유효한 인자를 돌려주는 `cases["도구이름"] = lambda: {...}` 추가 (필수 인자는 `inputSchema.required` 와 대조해 빠지면 실패)
3. `CALL_ORDER` 에 호출 순서 추가(데이터를 만드는 도구는 읽는 도구보다 앞에)
4. 필요하면 `make()` 안에 결과 검증 추가

실패 메시지는 "빠진 도구 / 기대에 없는 도구 / 호출 사례 없는 도구" 를 이름으로 알려 준다. 잘못된 인자 점검은 `inputSchema` 에서 자동으로 만들므로 따로 추가할 필요가 없다.

## 알려진 서버 결함

회귀 방지를 위해 점검은 유지하고, 결함으로 지금 실패하는 점검은 `run.py` 의 `KNOWN_DEFECTS` 에 설명을 적어 요약에 따로 표시한다. 고치면 그 항목을 지운다.

## CI

`.github/workflows/e2e.yml`: `local` 잡(push·PR·수동, PostgreSQL 서비스 + `run_local.sh`), `live` 잡(수동·매일, `vars.E2E_BASE_URL` 의 배포 서버를 임시 계정으로 점검, `secrets.E2E_SIGNUP_CODE` 없으면 경고 후 건너뜀, 재시작 없음).
