# 원격 MCP 서버 (A2 소유)

## 1. 전송
- MCP 사양 **2025-06-18**, **Streamable HTTP** 전송, 경로 `POST/GET /mcp` (같은 서버 프로세스, API와 같은 호스트)
- 도구(tools)만 제공한다. resources·prompts는 v0.3에서 없음. 단, 서버 `instructions`에 단위(kg)·시간대·충돌 규칙 요약을 넣는다
- 응답 텍스트는 사람이 읽을 요약 한 줄 + `structuredContent`(JSON). 출력 스키마(`outputSchema`)를 도구마다 선언
- 세션: `initialize` 가 `Mcp-Session-Id`(서명 토큰)를 주지만 **보안 경계가 아니다**(인증은 Bearer 토큰). 세션 헤더가 없거나, 검증에 실패한(다른 연결·만료·DELETE 로 닫은) 세션이어도 요청을 그대로 처리한다(상태 없는 서버). 서버는 이를 INFO 로그로만 남긴다. `DELETE /mcp`: 검증되는 세션이면 200, 아니면 404
- 진단: `GET /health/mcp-trace`(env `MCP_TRACE=true`, 비밀번호 로그인 서버는 기본 켜짐, 꺼지면 404)가 최근 100건 /mcp 요청의 메서드·도구 이름·상태·클라이언트(User-Agent, clientInfo)·세션/인증 여부를 보여준다. 토큰·id·인자·결과는 없다
- 호출 한도: 토큰당 분당 60회, 쓰기 도구는 분당 20회(429 → MCP 에러 `RATE_LIMITED`)

## 2. 인증 (OAuth 2.1)
Claude·ChatGPT·Gemini가 사람 개입 없이 연결할 수 있게 MCP 인증 사양을 따른다.
- 보호 자원 메타데이터: `GET /.well-known/oauth-protected-resource` → `{ resource: "<base>/mcp", authorization_servers: ["<base>"], scopes_supported: ["fitlog.read","fitlog.write"] }`. 401 응답에 `WWW-Authenticate: Bearer resource_metadata="..."`
- 인가 서버 메타데이터: `GET /.well-known/oauth-authorization-server` (RFC 8414)
- 동적 클라이언트 등록: `POST /oauth/register` (RFC 7591). `client_name`, `redirect_uris` 필수. 공개 클라이언트(`token_endpoint_auth_method: none`)만
- 인가 코드 + **PKCE S256 필수**. `GET /oauth/authorize` → 서버가 그리는 웹 페이지: Google로 로그인(웹 OAuth 클라이언트) → 동의 화면("{client_name}이 내 운동 기록을 읽고/추가합니다", 체크할 권한) → 코드 발급
- `POST /oauth/token`: `authorization_code`, `refresh_token`(회전, 재사용 감지 시 그 연결 전부 폐기). 액세스 토큰 1시간(불투명, 해시 저장), 리프레시 30일
- `resource` 파라미터(RFC 8707) 받으면 `<base>/mcp`와 같아야 함
- 권한: `fitlog.read` = 조회 도구, `fitlog.write` = 쓰기 도구 + read. 동의 화면에서 쓰기를 끄면 read만
- 연결 하나 = OAuth 클라이언트 + 사용자 한 쌍(`ai_connection`). 앱에서 목록을 보고 끊을 수 있다(A3)

## 3. 도구

공통: 모든 무게 kg, 시각 ISO-8601, 날짜 `YYYY-MM-DD`(사용자 시간대 기준). id는 UUID 문자열.

### 조회 (`fitlog.read`)
| 도구 | 입력 | 출력 |
| --- | --- | --- |
| `get_profile` | 없음 | 단위 설정, 시간대(최근 세션 tz), 체중 최신값, 1RM 추정식 |
| `search_exercises` | `query?`, `muscle?`, `type?`, `limit?=20` | 종목 목록(id, 이름, 유형, 부위, 기본 여부) |
| `list_programs` | `source?: TEMPLATE\|MINE` | 프로그램 요약 |
| `get_program` | `id` 또는 `templateKey` | 정의 전체(program.schema.json) |
| `validate_program` | `definition` | 유효 여부, 에러(JSON 포인터 경로) |
| `list_program_instances` | `status?` | 인스턴스(상태, TM·작업 무게, 주차) |
| `get_plan` | `instanceId`, `count?=3` | 다음 회차 계획(v0.2 PlannedWorkout) |
| `list_sessions` | `from?`, `to?`, `limit?=20` | 세션 요약(날짜, 종목 수, 세트 수, 볼륨) |
| `get_session` | `id` | 세션 전체(종목·세트·계획 목표) |
| `get_exercise_records` | `exerciseId` | PR·1RM(v0.2 ExerciseRecords) |
| `get_exercise_progress` | `exerciseId`, `from?`, `to?`, `limit?=100` | 종목 추이(v1.0 ExerciseProgress, REST `/v1/exercises/{id}/progress`와 같음) |
| `get_training_summary` | `from`, `to` | 종목별 세트 수·볼륨·최고 무게·최고 추정 1RM, 주 단위 운동 횟수 |
| `get_body_measurements` | `from?`, `to?` | 체중 기록 |
| `list_deletion_requests` | `status?` | 이 연결이 만든 삭제 요청과 상태 |
| `search` | `query` | OpenAI(ChatGPT) 커넥터 호환. 종목·세션(날짜/종목)·프로그램·인스턴스 검색. `{results:[{id,title,url}]}`(id 는 `session:`/`exercise:`/`program:`/`instance:` + uuid). content 텍스트도 같은 JSON 문자열 |
| `fetch` | `id` | search 의 id 로 `{id,title,text,url,metadata}`(읽기 좋은 요약). content 텍스트는 JSON 문자열. 모르는 id 는 도구 오류 |

### 쓰기 (`fitlog.write`) — 모두 `import.md` 파이프라인을 거친다
| 도구 | 입력 | 동작 |
| --- | --- | --- |
| `import_bundle` | `bundle`(import.schema.json), `resolutions?`, `onConflict?: ASK\|SKIP_ALL` | 묶음 가져오기. 충돌이 남으면 저장하지 않고 충돌 목록 반환(`status: "NEEDS_RESOLUTION"`). 성공 시 `ImportBatch` |
| `create_program` | `definition`, `onConflict?` | 묶음 `{programs:[...]}`로 감싸 가져오기 |
| `start_program` | `program`(id·templateKey), `startDate`, `tm?`, `working?`, `skipPolicy?` | 묶음 `{startPrograms:[...]}`. 값이 모자라면 `INSTANCE_NEEDS_VALUE` 충돌과 제안값 반환 |
| `log_session` | `session`(import.schema.json session), `resolutions?`, `onConflict?` | 묶음 `{sessions:[...]}` |
| `log_body_weight` | `measuredAt`, `weightKg` | 묶음 `{bodyMeasurements:[...]}` |
| `create_exercise` | import.schema.json exercise | 묶음 `{exercises:[...]}` |
| `adjust_program_instance` | `instanceId`, `tm?`, `working?`, `status?: ACTIVE\|PAUSED` | v0.2 PATCH와 같음. `FINISHED`·삭제는 불가 |
| `request_deletion` | `entity: session\|program\|program_instance\|exercise\|body_measurement`, `id`, `reason` | **삭제 요청만 만든다**. 상태 PENDING. 사용자가 앱에서 승인하면 실행 |

- 삭제·되돌리기·계정 관련 도구는 없다
- 쓰기 도구 응답에는 항상 `importBatchId`(있으면)와 "앱의 AI 기록에서 되돌릴 수 있습니다" 안내를 넣는다

## 4. 삭제 요청 (AI-5)
- 같은 대상에 PENDING 요청이 이미 있으면 새로 만들지 않고 기존 요청을 돌려준다
- 7일 동안 결정이 없으면 `EXPIRED`
- 승인하면 서버가 일반 삭제 경로(소프트 삭제, 동기화 전파, 필요하면 replay)로 실행한다. 대상이 이미 없으면 `APPROVED`로 닫고 `note: already deleted`
- v0.3에는 푸시 알림이 없다. 앱이 시작·포그라운드 때 PENDING 개수를 조회해 배너로 알린다

## 5. 보안
- 도구 입력은 import 스키마 검증을 그대로 거친다. 사용자 id는 토큰에서만 정한다(입력으로 받지 않음)
- 도구 설명·응답에 다른 사용자 데이터나 서버 내부 정보를 넣지 않는다
- 모든 MCP 호출을 `ai_tool_call` 로그(연결, 도구, 결과 코드, 소요 시간)로 남긴다. 입력 본문은 남기지 않는다

> v1.0 추가: 도구 `schedule_workout`, `list_scheduled_workouts`, `skip_scheduled_workout`과 `request_deletion` entity `scheduled_workout`은 `../v1.0/scheduled-workout.md` §9.
