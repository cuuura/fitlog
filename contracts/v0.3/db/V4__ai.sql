-- v0.3 스키마 변경. 소유: A1 (A2·A3 사용).

-- AI-6 가져오기 묶음과 항목
CREATE TABLE import_batch (
    id              uuid PRIMARY KEY,
    user_id         uuid NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
    channel         text NOT NULL CHECK (channel IN ('APP_JSON','MCP')),
    client_name     text,
    ai_connection_id uuid,                            -- MCP일 때 (FK는 아래에서)
    note            text,
    bundle_hash     text NOT NULL,                    -- 정규화한 묶음 SHA-256 (멱등 판단 보조)
    summary         jsonb NOT NULL DEFAULT '{}',
    created_at      timestamptz NOT NULL DEFAULT now(),
    reverted_at     timestamptz
);
CREATE INDEX import_batch_user_idx ON import_batch(user_id, created_at DESC);

CREATE TABLE import_item (
    id              uuid PRIMARY KEY,
    batch_id        uuid NOT NULL REFERENCES import_batch(id) ON DELETE CASCADE,
    entity          text NOT NULL CHECK (entity IN ('exercise','program','program_instance','workout_session','body_measurement')),
    entity_id       uuid NOT NULL,
    action          text NOT NULL CHECK (action IN ('CREATED','REPLACED_OLD')),
    label           text
);
CREATE INDEX import_item_batch_idx ON import_item(batch_id);

ALTER TABLE exercise         ADD COLUMN import_batch_id uuid REFERENCES import_batch(id) ON DELETE SET NULL;
ALTER TABLE program          ADD COLUMN import_batch_id uuid REFERENCES import_batch(id) ON DELETE SET NULL;
ALTER TABLE program_instance ADD COLUMN import_batch_id uuid REFERENCES import_batch(id) ON DELETE SET NULL;
ALTER TABLE workout_session  ADD COLUMN import_batch_id uuid REFERENCES import_batch(id) ON DELETE SET NULL;
ALTER TABLE body_measurement ADD COLUMN import_batch_id uuid REFERENCES import_batch(id) ON DELETE SET NULL;
ALTER TABLE body_measurement DROP CONSTRAINT body_measurement_source_check;
ALTER TABLE body_measurement ADD CONSTRAINT body_measurement_source_check
    CHECK (source IN ('MANUAL','HEALTH_CONNECT','HEALTHKIT','OCR','AI_JSON','AI_MCP','IMPORT'));
ALTER TABLE exercise ADD COLUMN source text NOT NULL DEFAULT 'APP' CHECK (source IN ('APP','AI_JSON','AI_MCP','IMPORT'));

-- AI-3 OAuth (MCP 인증)
CREATE TABLE oauth_client (
    id              uuid PRIMARY KEY,
    client_id       text NOT NULL UNIQUE,             -- 외부에 주는 값
    client_name     text NOT NULL,
    redirect_uris   text[] NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE ai_connection (
    id              uuid PRIMARY KEY,
    user_id         uuid NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
    client_id       uuid NOT NULL REFERENCES oauth_client(id) ON DELETE CASCADE,
    scopes          text[] NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    last_used_at    timestamptz,
    revoked_at      timestamptz,
    UNIQUE (user_id, client_id)
);
ALTER TABLE import_batch ADD CONSTRAINT import_batch_ai_connection_fk
    FOREIGN KEY (ai_connection_id) REFERENCES ai_connection(id) ON DELETE SET NULL;

CREATE TABLE oauth_auth_code (
    code_hash       text PRIMARY KEY,
    connection_id   uuid NOT NULL REFERENCES ai_connection(id) ON DELETE CASCADE,
    redirect_uri    text NOT NULL,
    code_challenge  text NOT NULL,                    -- S256
    scopes          text[] NOT NULL,
    expires_at      timestamptz NOT NULL,             -- 발급 후 10분
    used_at         timestamptz
);

CREATE TABLE oauth_token (
    id              uuid PRIMARY KEY,
    connection_id   uuid NOT NULL REFERENCES ai_connection(id) ON DELETE CASCADE,
    kind            text NOT NULL CHECK (kind IN ('ACCESS','REFRESH')),
    token_hash      text NOT NULL UNIQUE,
    family_id       uuid NOT NULL,                    -- 리프레시 회전 계열(재사용 감지 시 계열 전체 폐기)
    expires_at      timestamptz NOT NULL,
    revoked_at      timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX oauth_token_connection_idx ON oauth_token(connection_id);

CREATE TABLE ai_tool_call (
    id              bigserial PRIMARY KEY,
    connection_id   uuid NOT NULL REFERENCES ai_connection(id) ON DELETE CASCADE,
    tool            text NOT NULL,
    result_code     text NOT NULL,                    -- OK, NEEDS_RESOLUTION, VALIDATION_FAILED, RATE_LIMITED, ERROR
    duration_ms     integer NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ai_tool_call_conn_idx ON ai_tool_call(connection_id, created_at DESC);

-- AI-5 삭제 요청
CREATE TABLE deletion_request (
    id              uuid PRIMARY KEY,
    user_id         uuid NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
    connection_id   uuid REFERENCES ai_connection(id) ON DELETE SET NULL,
    client_name     text,
    entity          text NOT NULL CHECK (entity IN ('workout_session','program','program_instance','exercise','body_measurement')),
    entity_id       uuid NOT NULL,
    label           text,
    reason          text,
    status          text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','APPROVED','REJECTED','EXPIRED')),
    note            text,
    created_at      timestamptz NOT NULL DEFAULT now(),
    expires_at      timestamptz NOT NULL,
    decided_at      timestamptz
);
CREATE INDEX deletion_request_user_idx ON deletion_request(user_id, status, created_at DESC);
CREATE UNIQUE INDEX deletion_request_pending_uq ON deletion_request(user_id, entity, entity_id) WHERE status = 'PENDING';
