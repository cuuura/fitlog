# 오프라인 기록·동기화 규칙 (LOG-8)

소유: 서버 A3, 앱 B3. 앱은 **로컬 DB가 진실의 원천**처럼 동작하고, 서버와는 push/pull로 맞춘다.

## 대상 엔티티
`exercise`(사용자 종목만), `workout_session`, `session_exercise`, `workout_set`, `body_measurement`

## 앱 쪽
1. 모든 쓰기는 먼저 로컬 DB(drift)에 저장하고, 같은 트랜잭션에서 `outbox`에 변경을 쌓는다 `{entity, id, op: UPSERT|DELETE, payload, clientUpdatedAt}`
2. 네트워크가 되면 outbox를 오래된 순으로 최대 200개씩 `POST /v1/sync/push`
3. 그다음 `GET /v1/sync/pull?since=<lastServerSeq>`로 서버 변경을 받아 로컬에 덮어쓴다. 응답의 `nextSince`를 저장하고 `hasMore`가 false일 때까지 반복
4. 트리거: 앱 시작, 포그라운드 복귀, 세트 완료 후 5초 디바운스, 네트워크 복구, 세션 종료
5. 실패 시 지수 백오프(5s → 최대 5분). 로그인 만료(401)면 토큰 갱신 후 재시도

## 서버 쪽
- push의 각 변경은 독립 처리한다. 결과를 변경마다 `applied | conflict | rejected`로 돌려준다
- 충돌 규칙: **last-write-wins, `clientUpdatedAt` 기준**. 서버 행의 `updated_at`이 더 최신이면 `conflict`로 돌려주고 서버 값을 응답에 담는다(앱은 서버 값으로 덮어씀)
- 부모가 아직 없으면(예: 세트가 세션보다 먼저 도착) `rejected` + `code: PARENT_MISSING`. 앱은 다음 push에서 다시 보낸다. 앱은 부모부터 보내는 순서를 지킨다
- 삭제는 `deleted_at`을 채우는 소프트 삭제. pull에 삭제도 포함된다
- 변경된 행은 `server_seq`를 새로 매긴다. pull은 `server_seq > since` 행을 `server_seq` 순으로 최대 500개
- 같은 push를 두 번 받아도 결과가 같아야 한다(멱등)

## 세션 진행 중 규칙
- 진행 중 세션은 `ended_at = null`. 앱은 한 번에 하나의 진행 중 세션만 연다(v0.1)
- 앱이 강제 종료돼도 로컬 DB에서 진행 중 세션을 복구해 이어서 기록한다
