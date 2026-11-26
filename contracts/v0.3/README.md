# v0.3 계약 — AI 연동

v0.1·v0.2 계약에 **더하는** 계약이다. WP는 이 계약을 바꾸지 않는다. 바꿔야 하면 트랙 리드에게 올린다.

| 파일 | 내용 | 주 사용자 |
| --- | --- | --- |
| `import.schema.json` | AI·사용자가 넣는 묶음(bundle) JSON 형식. 프로그램 정의는 v0.2 `program.schema.json` 그대로 | A1, A2, B1 |
| `import.md` | 가져오기 규칙: 이름 해석, 충돌 종류·해결, 바로 저장, 출처, 되돌리기 | A1(소유), A2, B1, B2 |
| `mcp.md` | 원격 MCP 서버: 전송 방식, OAuth, 도구 목록·입출력, 권한, 삭제 승인 | A2(소유), A3, B3 |
| `export.md` | CSV·JSON 내보내기 형식 | A3, B3 |
| `prompt.md` | 앱의 "AI에게 줄 프롬프트 복사" 문구 | B1 |
| `openapi.yaml` | v0.3에서 추가되는 REST API | A1, A3, B1~B3 |
| `db/V4__ai.sql` | 가져오기 묶음, 출처 컬럼, 삭제 요청, OAuth 테이블 | A1(소유), A2·A3 사용 |

## 결정 사항 (기능 정의서 기준)
- AI 입력은 **충돌이 없으면 바로 저장**하고, 충돌이 있을 때만 해결을 요구한다
- AI가 넣은 모든 데이터에 출처(어느 AI, 언제, 어떤 묶음)를 남기고, 묶음 단위로 되돌릴 수 있다
- AI는 데이터를 **직접 지울 수 없다**. 삭제는 요청만 하고 사용자가 앱에서 승인해야 실행된다
- MCP는 Claude·ChatGPT·Gemini가 모두 붙을 수 있는 **원격 MCP**(Streamable HTTP + OAuth 2.1)
- 계산은 계속 서버 엔진만 한다. AI는 계획을 읽고 기록을 넣을 뿐, 무게 계산 규칙을 바꾸지 않는다

## WP와 소유 디렉터리

| WP | 소유 | 범위(기능 ID) | 완료 기준 |
| --- | --- | --- | --- |
| A1 가져오기 API | `server/.../importing/`, `db/migration/V4`, 공개 스키마 경로 | AI-1, AI-2(서버), AI-6 | `import.md`의 충돌 7종·해결·되돌리기 통합 테스트 통과, 같은 묶음 재전송이 멱등 |
| A2 원격 MCP·OAuth | `server/.../mcp/`, `server/.../oauth/`, 로그인·동의 웹 페이지 | AI-3, AI-5 | MCP Inspector로 도구 전부 호출 성공, OAuth 동적 등록·PKCE·토큰 갱신 테스트, Claude·ChatGPT·Gemini 중 2곳 연결 절차 문서 |
| A3 내보내기·삭제 승인·연결 관리 | `server/.../export/`, `.../deletion/`, `.../aiconnection/` | DAT-1, DAT-2, AI-5(승인) | CSV·JSON 내보내기, JSON 내보내기를 다시 가져오면 같은 데이터, 삭제 요청 승인·거절·만료 |
| B1 JSON 가져오기 UI | `app/lib/features/importing/` | AI-1, AI-2 | 붙여넣기·파일 선택, 미리보기, 충돌별 해결 선택, 결과 화면, 프롬프트 복사 |
| B2 AI 이력·승인 UI | `app/lib/features/ai_history/`, `.../deletion_requests/`, 출처 배지 위젯 | AI-5, AI-6 | 가져오기 이력·되돌리기, 세션·프로그램에 출처 배지, 삭제 요청 목록·승인·거절, 앱 시작 시 대기 요청 안내 |
| B3 AI 연결·내보내기 UI | `app/lib/features/ai_connect/`, `.../export/` | AI-2, AI-3, DAT-1, DAT-2 | AI별 연결 안내(MCP 주소 복사), 연결된 AI 목록·연결 끊기, 내보내기 후 공유 시트 |

공통 골격(DTO, API 클라이언트, 저장소 인터페이스, 라우트)은 트랙 리드가 WP 시작 전에 만든다.

## v0.3 완료 기준
1. AI가 만든 묶음 JSON을 앱에 붙여넣으면 충돌이 없을 때 바로 저장되고, 충돌이 있으면 해결을 고른 뒤 저장된다.
2. Claude·ChatGPT·Gemini 중 2곳 이상에서 MCP로 프로그램을 만들고 시작하고, 기록을 넣고, 기록·PR을 조회할 수 있다.
3. AI가 넣은 데이터에 출처가 보이고, 묶음 단위로 되돌릴 수 있다.
4. AI의 삭제 요청은 앱에서 승인해야만 실행된다.
5. JSON 내보내기 파일을 새 계정에 가져오면 같은 기록이 된다.

## 실기기·외부 확인 (사용자)
- MCP 연결은 공개 주소가 있는 서버가 필요하다. 리드가 임시 배포(또는 터널) 방법과 AI별 연결 절차를 `server/README.md`에 적고, 실제 연결 확인은 사용자에게 요청한다
- v0.1·v0.2 실기기 확인 7항목(`app/README.md`)은 그대로 남아 있다
