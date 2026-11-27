-- v1.0 보완: 테스트용 아이디·비밀번호 로그인. app_user 는 바꾸지 않는다.
CREATE TABLE password_credential (
    user_id        uuid PRIMARY KEY REFERENCES app_user(id) ON DELETE CASCADE,
    username       text NOT NULL UNIQUE,
    password_hash  text NOT NULL,
    failed_count   integer NOT NULL DEFAULT 0,
    locked_until   timestamptz,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now()
);
