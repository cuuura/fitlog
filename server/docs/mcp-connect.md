# 원격 MCP 연결 가이드 (v0.3)

Claude·ChatGPT·Gemini가 내 Fitlog 서버의 운동 기록을 읽고 추가하게 하는 방법이다. 서버는 **원격 MCP**(Streamable HTTP, 사양 2025-06-18)와 **OAuth 2.1**(동적 클라이언트 등록 + PKCE S256)을 제공한다.

> 각 제품(Claude, ChatGPT, Gemini)의 메뉴 이름과 위치는 자주 바뀐다. 아래 UI 명칭은 작성 시점 기준이며, 달라졌으면 비슷한 이름("커넥터", "앱", "MCP 서버", "개발자 모드")을 찾아 같은 값을 넣으면 된다.

핵심 주소(`<PUBLIC_BASE_URL>`은 아래 1단계에서 정한 공개 주소):

| 용도 | 주소 |
| --- | --- |
| MCP 서버 | `<PUBLIC_BASE_URL>/mcp` |
| 보호 자원 메타데이터 | `<PUBLIC_BASE_URL>/.well-known/oauth-protected-resource` |
| 인가 서버 메타데이터 | `<PUBLIC_BASE_URL>/.well-known/oauth-authorization-server` |
| 동적 클라이언트 등록 | `<PUBLIC_BASE_URL>/oauth/register` |
| Google 로그인 콜백 | `<PUBLIC_BASE_URL>/oauth/google/callback` |

## 1. 로컬 서버를 공개 주소로 열기

AI 서비스는 인터넷에서 서버를 호출하므로 `https` 공개 주소가 필요하다. 로컬에서 서버를 8080 포트로 띄우고 터널을 만든다.

### 방법 A. cloudflared quick tunnel (계정 불필요)

```bash
cloudflared tunnel --url http://localhost:8080
```

출력에 `https://<무작위>.trycloudflare.com` 주소가 나온다. quick tunnel은 **실행할 때마다 주소가 바뀐다**. 주소가 바뀌면 아래 2·3단계(환경변수, Google 리디렉션 URI)와 AI 쪽 커넥터를 다시 맞춰야 한다.

### 방법 B. ngrok

```bash
ngrok http 8080
```

`Forwarding https://<무작위>.ngrok-free.app -> http://localhost:8080` 의 https 주소를 쓴다. 고정 도메인을 받았다면 `ngrok http --domain=<내도메인> 8080`.

### 서버에 공개 주소 알리기 (`PUBLIC_BASE_URL`)

서버는 메타데이터·리디렉션·`WWW-Authenticate` 헤더에 이 값을 쓴다. **끝에 슬래시를 붙이지 않는다.**

```bash
export PUBLIC_BASE_URL=https://example.trycloudflare.com
export GOOGLE_WEB_CLIENT_ID=<아래 2단계에서 만든 웹 클라이언트 ID>
export GOOGLE_WEB_CLIENT_SECRET=<웹 클라이언트 보안 비밀>
# 기존 필수 값: JWT_SECRET, DB_URL/DB_USER/DB_PASSWORD, GOOGLE_CLIENT_IDS(앱 로그인용)
cd server && ./gradlew run
```

확인:

```bash
curl -s $PUBLIC_BASE_URL/.well-known/oauth-protected-resource
# {"resource":"https://example.trycloudflare.com/mcp","authorization_servers":[...],...}
curl -si -X POST $PUBLIC_BASE_URL/mcp -H 'content-type: application/json' -d '{}' | head -5
# HTTP/1.1 401 ... WWW-Authenticate: Bearer resource_metadata="https://example.trycloudflare.com/.well-known/oauth-protected-resource"
```

## 2. Google Cloud 콘솔에서 웹 OAuth 클라이언트 만들기

MCP 연결 때 사용자는 서버가 그리는 로그인 페이지에서 **Google 계정으로 로그인**한다(앱 로그인과 같은 계정이어야 같은 기록이 보인다). 이를 위해 **웹 애플리케이션** 유형의 OAuth 클라이언트가 필요하다. (앱용 Android 클라이언트와 별개다.)

1. [Google Cloud 콘솔](https://console.cloud.google.com/) → 앱에 쓰는 프로젝트 선택
2. **API 및 서비스 → OAuth 동의 화면**: 아직 없으면 만든다(테스트 모드면 "테스트 사용자"에 본인 계정 추가)
3. **API 및 서비스 → 사용자 인증 정보 → 사용자 인증 정보 만들기 → OAuth 클라이언트 ID**
4. 애플리케이션 유형 **웹 애플리케이션**
5. **승인된 리디렉션 URI**에 `<PUBLIC_BASE_URL>/oauth/google/callback` 추가 (예: `https://example.trycloudflare.com/oauth/google/callback`)
6. 만들면 나오는 **클라이언트 ID**를 `GOOGLE_WEB_CLIENT_ID`, **보안 비밀**을 `GOOGLE_WEB_CLIENT_SECRET`에 넣는다

주의: 리디렉션 URI는 `PUBLIC_BASE_URL`과 **글자 하나까지 같아야** 한다. quick tunnel 주소가 바뀌면 이 URI도 바꿔야 한다. 변경이 반영되는 데 몇 분 걸릴 수 있다.

## 3. MCP Inspector로 먼저 확인하기

AI 서비스에 붙이기 전에 Inspector로 OAuth와 도구를 점검하면 문제를 빨리 찾는다.

```bash
npx @modelcontextprotocol/inspector
```

1. Transport Type: **Streamable HTTP**, URL: `<PUBLIC_BASE_URL>/mcp`
2. **Open Auth Settings** → **Quick OAuth Flow** (또는 Connect 시 자동 안내). 브라우저에서 Google 로그인 → 동의 화면에서 **허용**
3. **Connect** 후 **Tools → List Tools**에 도구 27개(조회 17, 쓰기 10)가 보이는지 확인
4. `get_profile`, `list_programs`를 실행해 결과(요약 한 줄 + structuredContent)를 확인

쓰기 도구는 동의 화면에서 "기록 추가·수정 허용"을 켠 연결에서만 동작한다. 읽기만 허용했으면 쓰기 도구는 "권한 없음" 오류를 돌려준다.

## 테스트 서버(아이디·비밀번호)로 연결

Google 설정 없이 `PASSWORD_LOGIN_ENABLED=true` 로 돌리는 테스트 서버(예: Render)에서는 연결 창에 아이디·비밀번호 로그인이 뜬다. 앱에 로그인한 그 계정을 그대로 쓰면 된다. (Google 웹 클라이언트도 설정돼 있으면 "Google로 계속하기"가 함께 보인다.)

- MCP 주소: `https://<서버>/mcp`
- ChatGPT: 설정 → 앱과 커넥터(Apps & Connectors) → 고급에서 개발자 모드 켜기 → 커넥터 만들기 → URL 입력, 인증은 OAuth → 뜨는 로그인 창에서 앱의 아이디·비밀번호 입력 → 허용
- Claude: 설정 → 커넥터 → 사용자 지정 커넥터 추가 → URL 입력 → 연결 → 같은 로그인 창에서 아이디·비밀번호 입력 → 허용

주의: 대화 중에 "이 주소로 접속해 봐"라고 시키는 것은 커넥터 연결이 아니다. 반드시 위 절차로 커넥터를 추가해야 한다.

## 4. 제품별 연결

세 경우 모두 서버 주소로 `<PUBLIC_BASE_URL>/mcp`만 넣으면 된다. 클라이언트 ID·시크릿은 **넣지 않는다**(동적 클라이언트 등록으로 자동 처리).

### Claude (claude.ai / Claude 데스크톱·모바일)

1. **설정 → 커넥터 → 사용자 지정 커넥터 추가**(Settings → Connectors → Add custom connector)
2. 이름은 자유(예: Fitlog), URL에 `<PUBLIC_BASE_URL>/mcp` 입력 후 추가
3. 커넥터 목록에서 **연결**을 누르면 Fitlog 로그인 창이 열린다 → Google 로그인 → 동의 화면에서 **허용**
4. 새 대화에서 도구(커넥터) 메뉴로 Fitlog를 켜고 "내 최근 운동 기록 보여줘" 같은 질문을 한다

팀/Enterprise 플랜에서는 관리자가 커넥터를 추가해야 할 수 있다.

### ChatGPT

1. **설정 → 앱(또는 커넥터) → 고급 설정 → 개발자 모드** 켜기(Developer mode). 플랜·지역에 따라 제공 여부가 다르다
2. 개발자 모드에서 **새 앱(커넥터) 만들기**: 이름 Fitlog, MCP 서버 URL `<PUBLIC_BASE_URL>/mcp`, 인증은 **OAuth**
3. 만들기 후 **연결** → Fitlog 로그인 창에서 Google 로그인 → **허용**
4. 대화 입력창의 **+ / 도구**에서 개발자 모드와 Fitlog 커넥터를 선택하고 사용한다. 쓰기 도구는 ChatGPT가 호출 전 확인을 물을 수 있다

#### ChatGPT 점검 순서 (도구가 0개로 보일 때)

1. 설정 → 앱 → 고급 설정에서 **개발자 모드**를 켠다
2. **앱 만들기**: MCP 서버 URL `<PUBLIC_BASE_URL>/mcp`, 인증 OAuth → 로그인·허용
3. 서버를 다시 연결했거나 도구를 바꿨다면 앱 설정에서 **새로고침(Refresh)** 을 눌러 도구 목록을 다시 읽게 한다
4. 대화 입력창 **+ 메뉴**에서 이 앱을 켠다(웹에서 "앱 열기" 버튼만 보이면 데스크톱/앱에서 시도)
5. 서버는 `search`·`fetch` 읽기 도구도 제공한다(개발자 모드 밖 일반 채팅·deep research 용). 세션 헤더는 없어도 처리한다
6. 그래도 안 보이면 `GET <PUBLIC_BASE_URL>/health/mcp-trace`(`MCP_TRACE=true` 또는 테스트 서버)로 ChatGPT 가 /mcp 를 실제로 호출했는지(User-Agent, initialize, tools/list) 확인한다

### Gemini (Gemini CLI)

Gemini CLI의 `settings.json`(사용자 전체는 `~/.gemini/settings.json`, 프로젝트별은 `.gemini/settings.json`)에 원격 MCP 서버를 추가한다.

```json
{
  "mcpServers": {
    "fitlog": {
      "httpUrl": "https://example.trycloudflare.com/mcp"
    }
  }
}
```

1. 위처럼 `httpUrl`(Streamable HTTP)에 `<PUBLIC_BASE_URL>/mcp`를 넣고 Gemini CLI를 다시 시작
2. CLI 안에서 `/mcp auth fitlog`를 실행하면 브라우저가 열린다 → Google 로그인 → **허용**(OAuth는 동적 등록으로 자동)
3. `/mcp`로 서버가 `CONNECTED`이고 도구 27개가 보이는지 확인한 뒤 "내 운동 프로그램 목록 알려줘"처럼 요청한다

Gemini CLI의 인증 명령과 설정 키는 버전에 따라 다를 수 있으니 `/help`와 공식 문서를 함께 본다.

## 5. 연결 끊기·문제 해결

- **연결 끊기**: Fitlog 앱의 AI 연결 목록에서 끊는다. 끊으면 그 연결의 토큰이 즉시 무효가 된다(AI 쪽에서 다시 연결하면 새로 동의한다).
- **AI가 넣은 기록 되돌리기**: 앱의 AI 기록에서 묶음 단위로 되돌린다. AI는 데이터를 직접 지울 수 없고, `request_deletion`으로 **삭제 요청**만 만든다. 앱에서 승인해야 실행되고 7일이 지나면 만료된다.
- 한도: 액세스 토큰당 분당 60회, 쓰기 도구는 분당 20회. 넘으면 `RATE_LIMITED`(JSON-RPC 코드 -32029) 오류.
- 토큰 수명: 액세스 1시간, 리프레시 30일(사용할 때마다 회전). 재사용이 감지되면 그 연결의 토큰을 모두 폐기하니 다시 연결한다.

| 증상 | 확인할 것 |
| --- | --- |
| 커넥터 추가 시 "연결할 수 없음" | `PUBLIC_BASE_URL`이 현재 터널 주소와 같은지, 서버가 떠 있는지, `curl <PUBLIC_BASE_URL>/.well-known/oauth-protected-resource` 응답 |
| Google 로그인에서 `redirect_uri_mismatch` | 2단계의 승인된 리디렉션 URI가 `<PUBLIC_BASE_URL>/oauth/google/callback`과 정확히 같은지 |
| 로그인 후 "로그인 실패" | `GOOGLE_WEB_CLIENT_ID/SECRET`이 웹 클라이언트 값인지, 테스트 모드면 테스트 사용자에 계정이 있는지 |
| 로그인 페이지가 "Google 웹 로그인이 설정되지 않았습니다" | `GOOGLE_WEB_CLIENT_ID` 환경변수 |
| 도구는 보이는데 쓰기가 "권한 없음" | 동의 화면에서 쓰기 허용을 껐다. 커넥터를 끊고 다시 연결해 허용 |
| 터널 주소가 바뀜 | `PUBLIC_BASE_URL`, Google 리디렉션 URI, AI 쪽 커넥터 URL을 모두 새 주소로 |

## 연결 문제 진단 (테스트 서버)

비밀번호 로그인이 켜진 서버(또는 `MCP_TRACE=true`)에서는 `<PUBLIC_BASE_URL>/health/mcp-trace` 가 최근 MCP·OAuth·메타데이터 요청 200건을 보여 준다(경로, 상태 코드, User-Agent, 파라미터 이름, redirect 호스트, scope 등. 토큰·비밀번호·코드 값은 남기지 않음). AI 쪽에서 "연결하지 못했습니다"가 나오면 바로 열어 어느 단계(`/.well-known/*` → `/oauth/register` → `/oauth/authorize` → `/oauth/token` → `/mcp`)에서 멈췄는지 본다. 서버가 재시작되면 기록은 비워진다.

### 클라이언트 등록 방식 (DCR·CIMD)

서버는 두 방식을 모두 받는다. 동적 등록(DCR, `/oauth/register`)과 클라이언트 메타데이터 문서(CIMD: `client_id` 가 https URL 이고 서버가 그 JSON 문서를 받아 확인)다. ChatGPT 는 CIMD 를 우선 쓴다. 문서의 token_endpoint_auth_method(ChatGPT 는 private_key_jwt)는 검사하지 않고 PKCE·redirect_uri 정확 일치로 보호한다. CIMD 클라이언트는 동의 화면에 `이름 (도메인)` 으로 표시되고, 진단 기록에는 `cimd=1 cimd_host=<도메인>` 으로 남는다.
