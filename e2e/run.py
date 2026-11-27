#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Fitlog 블랙박스 E2E 테스트.

실제로 떠 있는 서버 프로세스에 진짜 HTTP 로 접속해서, 앱과 ChatGPT/Claude(원격 MCP + OAuth 2.1)가
하는 요청을 그대로 재현한다. 파이썬 3 표준 라이브러리만 쓴다(pip 불필요).

사용법:
  python3 e2e/run.py --base-url http://localhost:8080 --phase before-restart --signup-code CODE
  (서버 재시작)
  python3 e2e/run.py --base-url http://localhost:8080 --phase after-restart

phase:
  all             처음부터 끝까지(재시작 없음). 운영/테스트 서버 점검용
  before-restart  모든 점검 + 재시작 뒤에 확인할 값(토큰·세션 ID 등)을 --state 파일에 저장
  after-restart   --state 파일의 값으로 "재시작해도 살아있는가"만 점검

종료 코드: 모든 점검 통과 0, 하나라도 실패 1.
"""
import argparse
import base64
import hashlib
import http.client
import json
import os
import re
import secrets
import sys
import time
import urllib.parse
import uuid
from datetime import datetime, timedelta, timezone
from html.parser import HTMLParser

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# ---------------------------------------------------------------------------------------------
# 기대하는 MCP 도구 목록. 도구가 추가·삭제되면 여기와 CALL_CASES 를 함께 고친다.
# 서버 소스(server/src/main/kotlin/com/fitlog/mcp/)가 있으면 소스의 도구 이름과도 대조한다.
# ---------------------------------------------------------------------------------------------
EXPECTED_READ_TOOLS = [
    "get_profile", "search_exercises", "list_programs", "get_program", "validate_program",
    "list_program_instances", "get_plan", "list_sessions", "get_session", "get_exercise_records",
    "get_exercise_progress", "get_training_summary", "get_body_measurements", "list_deletion_requests",
    "list_scheduled_workouts",
    "search", "fetch",  # OpenAI(ChatGPT) 커넥터 호환 읽기 도구
]
EXPECTED_WRITE_TOOLS = [
    "import_bundle", "create_program", "start_program", "log_session", "log_body_weight",
    "create_exercise", "adjust_program_instance", "request_deletion",
    "schedule_workout", "skip_scheduled_workout",
]
EXPECTED_TOOLS = EXPECTED_READ_TOOLS + EXPECTED_WRITE_TOOLS

CHATGPT_REDIRECT = "https://chatgpt.com/connector_platform_oauth_redirect"
CLAUDE_REDIRECT = "https://claude.ai/api/mcp/auth_callback"

# 서버 결함으로 지금 실패하는 점검: {점검 이름: 설명}. 실패해도 회귀 방지용으로 유지하고, 요약에 따로 표시한다.
KNOWN_DEFECTS = {
    "oauth.consent_write_checkbox_is_inside_form":
        "OAuthPages.consent: 쓰기 체크박스가 <form> 밖에 있어 항상 읽기 전용 연결이 됨",
}


# =============================================================================================
# 작은 HTTP 도구
# =============================================================================================
class Resp:
    def __init__(self, status, headers, body):
        self.status = status
        self.headers = headers  # 소문자 키 -> 마지막 값
        self.raw_headers = headers
        self.body = body

    @property
    def text(self):
        return self.body.decode("utf-8", "replace")

    def json(self):
        return json.loads(self.body.decode("utf-8"))

    def h(self, name, default=None):
        return self.headers.get(name.lower(), default)


class Http:
    """리다이렉트를 따라가지 않는 HTTP 클라이언트(쿠키 보관 포함). 429 는 Retry-After 만큼 기다렸다 재시도한다."""

    def __init__(self, base_url, verbose=False):
        self.base = base_url.rstrip("/")
        u = urllib.parse.urlparse(self.base)
        self.scheme, self.host, self.port = u.scheme, u.hostname, u.port or (443 if u.scheme == "https" else 80)
        self.cookies = {}
        self.verbose = verbose

    def _conn(self, timeout):
        if self.scheme == "https":
            return http.client.HTTPSConnection(self.host, self.port, timeout=timeout)
        return http.client.HTTPConnection(self.host, self.port, timeout=timeout)

    def request(self, method, path, headers=None, json_body=None, form=None, raw=None, timeout=60,
                retry429=True, use_cookies=False):
        hdrs = {"User-Agent": "fitlog-e2e/1.0", "Accept": "*/*"}
        hdrs.update(headers or {})
        body = None
        if json_body is not None:
            body = json.dumps(json_body, ensure_ascii=False).encode("utf-8")
            hdrs.setdefault("Content-Type", "application/json")
        elif form is not None:
            body = urllib.parse.urlencode(form).encode("utf-8")
            hdrs.setdefault("Content-Type", "application/x-www-form-urlencoded")
        elif raw is not None:
            body = raw if isinstance(raw, bytes) else raw.encode("utf-8")
        if use_cookies and self.cookies:
            hdrs["Cookie"] = "; ".join(f"{k}={v}" for k, v in self.cookies.items())
        if path.startswith("http://") or path.startswith("https://"):
            u = urllib.parse.urlparse(path)
            path = u.path + (("?" + u.query) if u.query else "")
        for attempt in range(4):
            last_exc = None
            for conn_try in range(3):  # 콜드 스타트(무료 호스팅)·일시적 연결 오류 재시도
                conn = self._conn(timeout)
                try:
                    conn.request(method, path, body=body, headers=hdrs)
                    r = conn.getresponse()
                    data = r.read()
                    last_exc = None
                    break
                except (ConnectionError, OSError, http.client.HTTPException) as e:
                    last_exc = e
                    time.sleep(2 + conn_try * 3)
                finally:
                    conn.close()
            if last_exc is not None:
                raise last_exc
            headers_out = {}
            for k, v in r.getheaders():
                headers_out[k.lower()] = v
                if k.lower() == "set-cookie" and use_cookies:
                    kv = v.split(";", 1)[0]
                    if "=" in kv:
                        n, val = kv.split("=", 1)
                        self.cookies[n] = val
            resp = Resp(r.status, headers_out, data)
            if self.verbose:
                print(f"    {method} {path} -> {resp.status}", file=sys.stderr)
            if resp.status == 429 and retry429 and attempt < 3:
                wait = min(int(resp.h("retry-after", "10") or 10), 70) + 1
                print(f"    (429 호출 제한: {wait}초 대기 후 재시도 {method} {path})", file=sys.stderr)
                time.sleep(wait)
                continue
            return resp
        return resp

    def get(self, path, **kw):
        return self.request("GET", path, **kw)

    def post(self, path, **kw):
        return self.request("POST", path, **kw)


class HtmlForms(HTMLParser):
    """로그인·동의 페이지의 <form> 을 읽는다."""

    def __init__(self):
        super().__init__()
        self.forms = []
        self._cur = None
        self.title = ""
        self._in_title = False
        self.links = []

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "title":
            self._in_title = True
        elif tag == "form":
            self._cur = {"action": a.get("action", ""), "method": (a.get("method") or "get").lower(), "inputs": [], "buttons": []}
            self.forms.append(self._cur)
        elif tag == "input" and self._cur is not None:
            self._cur["inputs"].append({"name": a.get("name"), "type": (a.get("type") or "text").lower(),
                                        "value": a.get("value", ""), "checked": "checked" in a, "disabled": "disabled" in a})
        elif tag == "button" and self._cur is not None:
            self._cur["buttons"].append({"name": a.get("name"), "value": a.get("value", "")})
        elif tag == "a" and a.get("href"):
            self.links.append(a["href"])

    def handle_endtag(self, tag):
        if tag == "title":
            self._in_title = False
        elif tag == "form":
            self._cur = None

    def handle_data(self, data):
        if self._in_title:
            self.title += data


def parse_forms(html):
    p = HtmlForms()
    p.feed(html)
    return p


def b64url(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def new_pkce():
    verifier = b64url(secrets.token_bytes(48))
    return verifier, b64url(hashlib.sha256(verifier.encode()).digest())


def now_iso(delta_min=0):
    return (datetime.now(timezone.utc) + timedelta(minutes=delta_min)).strftime("%Y-%m-%dT%H:%M:%S.000Z")


# =============================================================================================
# 점검 실행 틀
# =============================================================================================
class Fail(Exception):
    pass


def expect(cond, msg):
    if not cond:
        raise Fail(msg)


def expect_status(resp, status, what=""):
    ok = resp.status in status if isinstance(status, (list, tuple, set)) else resp.status == status
    if not ok:
        raise Fail(f"{what} 기대 HTTP {status}, 실제 {resp.status}: {resp.text[:300]}")


class Runner:
    def __init__(self, args):
        self.args = args
        self.results = []  # (name, ok, msg, note)
        self.ctx = {}
        self.http = Http(args.base_url, verbose=args.verbose)
        self.public = (args.public_base_url or args.base_url).rstrip("/")

    def run(self, name, fn):
        t0 = time.time()
        try:
            note = fn()
            self.results.append((name, True, "", note or ""))
            print(f"  PASS  {name}" + (f"  ({note})" if note else ""), flush=True)
        except Fail as e:
            self.results.append((name, False, str(e), ""))
            tag = " [서버 결함 알려짐]" if name in KNOWN_DEFECTS else ""
            print(f"  FAIL  {name}{tag}\n        -> {e}", flush=True)
        except Exception as e:  # 예상 못한 오류도 점검 실패로 기록하고 계속한다
            import traceback
            self.results.append((name, False, f"{type(e).__name__}: {e}", ""))
            print(f"  FAIL  {name}\n        -> {type(e).__name__}: {e}", flush=True)
            if self.args.verbose:
                traceback.print_exc()
        _ = t0

    def need(self, *keys):
        for k in keys:
            if k not in self.ctx:
                raise Fail(f"선행 점검이 실패해 진행할 수 없음(필요한 값: {k})")
        return [self.ctx[k] for k in keys] if len(keys) > 1 else self.ctx[keys[0]]


# =============================================================================================
# 앱(REST) 도우미
# =============================================================================================
def api(R, method, path, token, json_body=None, **kw):
    hdrs = {"Authorization": f"Bearer {token}"} if token else {}
    return R.http.request(method, path, headers=hdrs, json_body=json_body, **kw)


def app_register(R, username, password="e2e-password-1", code=None, display=None):
    body = {"username": username, "password": password, "signupCode": code if code is not None else R.args.signup_code}
    if display:
        body["displayName"] = display
    return R.http.post("/v1/auth/password/register", json_body=body)


def detect_consent_version(args):
    if args.consent_version:
        return args.consent_version, "--consent-version"
    p = os.path.join(ROOT, "app", "lib", "core", "config.dart")
    if os.path.exists(p):
        m = re.search(r"consentVersion\s*=\s*'([^']+)'", open(p, encoding="utf-8").read())
        if m:
            return m.group(1), "app/lib/core/config.dart"
    return None, None


def server_consent_version():
    p = os.path.join(ROOT, "server", "src", "main", "kotlin", "com", "fitlog", "account", "AccountRoutes.kt")
    if os.path.exists(p):
        m = re.search(r'CURRENT_CONSENT_VERSION\s*=\s*"([^"]+)"', open(p, encoding="utf-8").read())
        if m:
            return m.group(1)
    return None


def server_tool_names():
    d = os.path.join(ROOT, "server", "src", "main", "kotlin", "com", "fitlog", "mcp")
    names = []
    for f in ("McpTools.kt", "McpWriteTools.kt", "McpCompatTools.kt"):
        p = os.path.join(d, f)
        if not os.path.exists(p):
            return None
        names += re.findall(r'^\s*name = "([a-z_]+)", title', open(p, encoding="utf-8").read(), re.M)
    return names


# =============================================================================================
# OAuth / MCP 도우미 (ChatGPT·Claude 가 하는 순서 그대로)
# =============================================================================================
def oauth_register(R, payload):
    r = R.http.post("/oauth/register", json_body=payload)
    return r


def oauth_login_and_consent(R, client_id, redirect_uri, username, password, allow_write=True, scope=None,
                            resource=None, state=None, decision="allow", challenge=None):
    """/oauth/authorize → 로그인 폼 제출 → 동의 폼 제출 → 리다이렉트 Location 에서 code 를 꺼낸다.
    리다이렉트는 따라가지 않는다(chatgpt.com 으로 가면 안 되므로). 반환: (Location 쿼리 dict, Location 원문)"""
    state = state or secrets.token_urlsafe(12)
    params = {"response_type": "code", "client_id": client_id, "redirect_uri": redirect_uri,
              "code_challenge": challenge, "code_challenge_method": "S256", "state": state}
    if scope:
        params["scope"] = scope
    if resource:
        params["resource"] = resource
    browser = Http(R.args.base_url)  # 브라우저처럼 쿠키를 따로 가진다
    r = browser.get("/oauth/authorize?" + urllib.parse.urlencode(params), use_cookies=True)
    expect(r.status == 200, f"/oauth/authorize 가 로그인 페이지(200)가 아님: {r.status} {r.text[:200]} Location={r.h('location')}")
    forms = parse_forms(r.text).forms
    expect(forms, f"로그인 페이지에 <form> 이 없음(비밀번호 로그인이 꺼져 있나?): {r.text[:300]}")
    form = forms[0]
    expect(form["method"] == "post", "로그인 폼 method 가 post 가 아님")
    # 폼 action 은 공개 주소여야 한다(프록시 뒤에서도 브라우저가 올바른 곳으로 제출하도록)
    expect(form["action"].startswith(R.public + "/") or form["action"].startswith("/"),
           f"로그인 폼 action 이 PUBLIC_BASE_URL({R.public}) 이 아님: {form['action']}")
    data = {i["name"]: i["value"] for i in form["inputs"] if i["name"] and i["type"] == "hidden"}
    data["username"], data["password"] = username, password
    r2 = browser.post(form["action"], form=data, use_cookies=True)
    expect(r2.status == 200, f"로그인 제출 후 동의 페이지(200) 기대, 실제 {r2.status}: {r2.text[:300]}")
    forms2 = parse_forms(r2.text).forms
    expect(forms2, "동의 페이지에 <form> 이 없음")
    f2 = forms2[0]
    data2 = {i["name"]: i["value"] for i in f2["inputs"] if i["name"] and i["type"] == "hidden"}
    data2["decision"] = decision
    # 브라우저는 <form> 안의 입력만 제출한다. 쓰기 체크박스가 폼 밖에 있으면 체크해도 서버로 가지 않는다
    in_form = any(i["name"] == "write" for i in f2["inputs"])
    has_write_box = in_form or bool(re.search(r'name="write"', r2.text))
    if allow_write and has_write_box:
        if not in_form:
            R.ctx["write_checkbox_outside_form"] = True  # 결함 기록. 나머지 점검을 위해 값은 대신 보내 준다
        data2["write"] = "1"
    r3 = browser.post(f2["action"], form=data2, use_cookies=True)
    expect(r3.status in (302, 303, 307), f"동의 제출 후 리다이렉트 기대, 실제 {r3.status}: {r3.text[:200]}")
    loc = r3.h("location", "")
    q = dict(urllib.parse.parse_qsl(urllib.parse.urlparse(loc).query))
    return q, loc, state, has_write_box


def token_request(R, grant_fields, auth_method, client_id, client_secret=None):
    form = dict(grant_fields)
    headers = {}
    if auth_method == "client_secret_basic":
        headers["Authorization"] = "Basic " + base64.b64encode(f"{client_id}:{client_secret}".encode()).decode()
    else:
        form["client_id"] = client_id
        if auth_method == "client_secret_post":
            form["client_secret"] = client_secret
    return R.http.request("POST", "/oauth/token", headers=headers, form=form)


def oauth_connect(R, reg_payload, auth_method, username, password, redirect_uri, allow_write=True,
                  scope=None, resource=None, reuse_client=None):
    """등록 → 인가(PKCE S256) → 로그인·동의 → 토큰 교환. 연결 정보를 dict 로 돌려준다."""
    if reuse_client:
        client_id, client_secret = reuse_client
    else:
        r = oauth_register(R, reg_payload)
        expect_status(r, (200, 201), "동적 클라이언트 등록")
        reg = r.json()
        client_id, client_secret = reg["client_id"], reg.get("client_secret")
        expect(reg.get("redirect_uris") == reg_payload["redirect_uris"], f"등록 응답 redirect_uris 불일치: {reg}")
    verifier, challenge = new_pkce()
    q, loc, state, has_write_box = oauth_login_and_consent(
        R, client_id, redirect_uri, username, password, allow_write, scope, resource, challenge=challenge)
    expect(loc.startswith(redirect_uri), f"리다이렉트가 등록한 redirect_uri 로 가지 않음: {loc}")
    expect("code" in q, f"리다이렉트에 code 없음: {loc}")
    expect(q.get("state") == state, f"state 가 되돌아오지 않음: {loc}")
    fields = {"grant_type": "authorization_code", "code": q["code"], "redirect_uri": redirect_uri, "code_verifier": verifier}
    if resource:
        fields["resource"] = resource
    t = token_request(R, fields, auth_method, client_id, client_secret)
    expect_status(t, 200, "토큰 교환")
    tok = t.json()
    expect(tok.get("token_type", "").lower() == "bearer", f"token_type 이 Bearer 가 아님: {tok}")
    expect(tok.get("access_token") and tok.get("refresh_token"), f"access/refresh 토큰 없음: {tok}")
    expect(isinstance(tok.get("expires_in"), int) and tok["expires_in"] > 0, f"expires_in 이상: {tok}")
    return {"client_id": client_id, "client_secret": client_secret, "redirect_uri": redirect_uri, "auth_method": auth_method,
            "access": tok["access_token"], "refresh": tok["refresh_token"], "scope": tok.get("scope", ""),
            "code": q["code"], "verifier": verifier, "has_write_box": has_write_box, "resource": resource}


def mcp_rpc(R, token, method, params=None, sid=None, rid=None, protocol=None, notify=False, timeout=60, extra=None):
    hdrs = {"Authorization": f"Bearer {token}", "Accept": "application/json, text/event-stream"}
    if sid:
        hdrs["Mcp-Session-Id"] = sid
    if protocol:
        hdrs["MCP-Protocol-Version"] = protocol
    hdrs.update(extra or {})
    body = {"jsonrpc": "2.0", "method": method}
    if not notify:
        body["id"] = rid if rid is not None else secrets.randbelow(10 ** 9)
    if params is not None:
        body["params"] = params
    return R.http.request("POST", "/mcp", headers=hdrs, json_body=body, timeout=timeout)


def mcp_init(R, token, protocol="2025-06-18"):
    r = mcp_rpc(R, token, "initialize", {
        "protocolVersion": protocol, "capabilities": {},
        "clientInfo": {"name": "fitlog-e2e", "version": "1.0"}}, protocol=None)
    expect_status(r, 200, f"initialize({protocol})")
    j = r.json()
    expect("result" in j, f"initialize 결과 없음: {j}")
    sid = r.h("mcp-session-id")
    expect(sid, "initialize 응답에 Mcp-Session-Id 헤더가 없음")
    n = mcp_rpc(R, token, "notifications/initialized", sid=sid, notify=True, protocol=protocol)
    expect(n.status in (200, 202), f"notifications/initialized 기대 202, 실제 {n.status}")
    return sid, j["result"]


def mcp_call_tool(R, token, sid, name, args, protocol="2025-06-18", retries=3):
    """tools/call. 호출 제한(-32029)이면 잠시 기다렸다 다시 시도한다. 반환: (HTTP 응답, JSON 본문)"""
    for _ in range(retries):
        r = mcp_rpc(R, token, "tools/call", {"name": name, "arguments": args}, sid=sid, protocol=protocol)
        j = None
        try:
            j = r.json()
        except Exception:
            pass
        if j and j.get("error", {}).get("code") == -32029:
            time.sleep(21)
            continue
        return r, j
    return r, j


def mcp_list_tools(R, token, sid, protocol="2025-06-18"):
    r = mcp_rpc(R, token, "tools/list", {}, sid=sid, protocol=protocol)
    expect_status(r, 200, "tools/list")
    j = r.json()
    expect("result" in j, f"tools/list 에러: {j}")
    return j["result"]["tools"]


def tool_ok(R, token, sid, name, args):
    """도구를 호출해 isError=false 와 outputSchema 필수 필드를 확인하고 structuredContent 를 돌려준다."""
    tools = R.ctx.get("_tools_by_name") or {}
    r, j = mcp_call_tool(R, token, sid, name, args)
    expect_status(r, 200, f"{name} 호출")
    expect("error" not in j, f"{name}: JSON-RPC 에러 {j.get('error')}")
    res = j["result"]
    text = (res.get("content") or [{}])[0].get("text", "")
    expect(res.get("isError") is False, f"{name}: isError={res.get('isError')} 텍스트={text[:300]} 인자={json.dumps(args, ensure_ascii=False)[:300]}")
    expect(res.get("content") and res["content"][0].get("type") == "text" and text, f"{name}: content 텍스트 요약이 없음")
    sc = res.get("structuredContent")
    schema = (tools.get(name) or {}).get("outputSchema")
    if schema:
        expect(isinstance(sc, dict), f"{name}: outputSchema 가 있는데 structuredContent 가 없음")
        missing = [k for k in schema.get("required", []) if k not in sc]
        expect(not missing, f"{name}: structuredContent 에 outputSchema 필수 필드 없음 {missing} (실제 키 {list(sc)})")
    return sc


# =============================================================================================
# 점검: 상태 파일
# =============================================================================================
def load_state(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return {}


def save_state(path, state):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(state, f, ensure_ascii=False, indent=2)


# =============================================================================================
# 점검 모음 — 헬스 / 메타데이터 / 프록시
# =============================================================================================
def c_health(R):
    def ready():
        deadline = time.time() + R.args.wait
        r = None
        while time.time() < deadline:
            try:
                r = R.http.get("/health/ready", timeout=30)
                if r.status == 200:
                    break
            except Exception:
                pass
            time.sleep(2)
        expect(r is not None and r.status == 200, f"/health/ready 가 200 이 아님: {r and r.status}")
        expect(r.text.strip() == "ok", f"/health/ready 본문이 ok 가 아님: {r.text[:100]}")
    R.run("health.ready", ready)

    def root():
        r = R.http.get("/health")
        expect_status(r, 200, "/health")
    R.run("health.basic", root)

    def live():
        r = R.http.get("/health/live")
        if r.status == 404:
            return "/health/live 는 서버에 없음(404) - /health/ready 만 사용"
        expect_status(r, 200, "/health/live")
    R.run("health.live(optional)", live)


def c_metadata(R):
    pub = R.public

    def prm(path):
        def f():
            r = R.http.get(path)
            expect_status(r, 200, path)
            expect("json" in r.h("content-type", ""), f"content-type 이 JSON 이 아님: {r.h('content-type')}")
            j = r.json()
            expect(j.get("resource") == pub + "/mcp", f"resource={j.get('resource')} 기대 {pub}/mcp")
            expect(j.get("authorization_servers") == [pub], f"authorization_servers={j.get('authorization_servers')} 기대 [{pub}]")
            expect("fitlog.read" in j.get("scopes_supported", []), f"scopes_supported={j.get('scopes_supported')}")
        return f
    R.run("oauth.protected_resource_metadata", prm("/.well-known/oauth-protected-resource"))
    R.run("oauth.protected_resource_metadata(/mcp suffix)", prm("/.well-known/oauth-protected-resource/mcp"))

    def asm(path):
        def f():
            r = R.http.get(path)
            expect_status(r, 200, path)
            j = r.json()
            expect(j.get("issuer") == pub, f"issuer={j.get('issuer')} 기대 {pub}")
            for k, p in (("authorization_endpoint", "/oauth/authorize"), ("token_endpoint", "/oauth/token"),
                         ("registration_endpoint", "/oauth/register")):
                expect(j.get(k) == pub + p, f"{k}={j.get(k)} 기대 {pub + p}")
            expect("S256" in j.get("code_challenge_methods_supported", []), "S256 PKCE 미지원으로 표시")
            expect("code" in j.get("response_types_supported", []), "response_types_supported 에 code 없음")
            g = j.get("grant_types_supported", [])
            expect("authorization_code" in g and "refresh_token" in g, f"grant_types_supported={g}")
            m = j.get("token_endpoint_auth_methods_supported", [])
            expect("none" in m and "client_secret_post" in m, f"token_endpoint_auth_methods_supported={m} (none, client_secret_post 필요)")
        return f
    R.run("oauth.authorization_server_metadata", asm("/.well-known/oauth-authorization-server"))
    R.run("oauth.authorization_server_metadata(/mcp suffix)", asm("/.well-known/oauth-authorization-server/mcp"))

    def oidc():
        r = R.http.get("/.well-known/openid-configuration")
        if r.status == 404:
            return "404 (서버가 제공하지 않음. 클라이언트는 oauth-authorization-server 로 폴백)"
        expect_status(r, 200, "openid-configuration")
        j = r.json()
        expect(j.get("authorization_endpoint") == pub + "/oauth/authorize", f"authorization_endpoint={j.get('authorization_endpoint')}")
        return "제공됨"
    R.run("oauth.openid_configuration(probe)", oidc)

    def unauth():
        r = R.http.post("/mcp", json_body={"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
                        headers={"Accept": "application/json, text/event-stream"})
        expect_status(r, 401, "인증 없는 POST /mcp")
        w = r.h("www-authenticate", "")
        expect(w.lower().startswith("bearer"), f"WWW-Authenticate 가 Bearer 가 아님: {w}")
        m = re.search(r'resource_metadata="([^"]+)"', w)
        expect(m, f"WWW-Authenticate 에 resource_metadata 없음: {w}")
        expect(m.group(1) == pub + "/.well-known/oauth-protected-resource", f"resource_metadata={m.group(1)} 기대 {pub}/.well-known/oauth-protected-resource")
        r2 = R.http.post("/mcp", json_body={"jsonrpc": "2.0", "id": 1, "method": "tools/list"},
                         headers={"Authorization": "Bearer not-a-real-token"})
        expect_status(r2, 401, "엉터리 토큰으로 POST /mcp")
        expect("resource_metadata" in r2.h("www-authenticate", ""), "잘못된 토큰 401 에도 resource_metadata 필요")
        r3 = R.http.get(m.group(1).replace(pub, ""))
        expect_status(r3, 200, "resource_metadata URL 이 실제로 열리는가")
    R.run("mcp.unauthenticated_401_with_resource_metadata", unauth)

    def proxy():
        # Render 같은 프록시 뒤: 메타데이터 URL 은 요청 헤더가 아니라 PUBLIC_BASE_URL 로 만들어야 한다
        fake = {"X-Forwarded-Proto": "https", "X-Forwarded-Host": "evil.example", "X-Forwarded-For": "203.0.113.77",
                "Forwarded": "for=203.0.113.77;proto=https;host=evil.example"}
        r = R.http.get("/.well-known/oauth-protected-resource", headers=fake)
        expect_status(r, 200, "프록시 헤더 + 메타데이터")
        expect(r.json().get("resource") == pub + "/mcp", f"프록시 헤더가 붙자 resource 가 바뀜: {r.json().get('resource')}")
        r = R.http.get("/.well-known/oauth-authorization-server", headers=fake)
        j = r.json()
        for k in ("issuer", "authorization_endpoint", "token_endpoint", "registration_endpoint"):
            expect(j[k].startswith(pub), f"프록시 헤더가 붙자 {k}={j[k]} (기대 {pub}...)")
        r = R.http.post("/mcp", json_body={"jsonrpc": "2.0", "id": 1, "method": "tools/list"}, headers=fake)
        expect_status(r, 401, "프록시 헤더 + 인증 없는 /mcp")
        expect(f'resource_metadata="{pub}/.well-known/oauth-protected-resource"' in r.h("www-authenticate", ""),
               f"프록시 헤더가 붙자 WWW-Authenticate 가 바뀜: {r.h('www-authenticate')}")
        # Host 헤더를 다른 값으로 바꿔도 마찬가지(http.client 는 Host 를 직접 지정할 수 있다)
        r = R.http.get("/.well-known/oauth-protected-resource", headers={"Host": "evil.example"})
        if r.status == 200:
            expect(r.json().get("resource") == pub + "/mcp", f"Host 헤더에 따라 resource 가 바뀜: {r.json().get('resource')}")
    R.run("proxy.metadata_uses_public_base_url", proxy)


# =============================================================================================
# 점검: 비밀번호 인증 / 동의 / 앱 REST 흐름
# =============================================================================================
def c_auth(R):
    a = R.args
    user = R.ctx["username"] = "e2e" + secrets.token_hex(5)
    pw = R.ctx["password"] = "e2e-password-1"

    def methods():
        r = R.http.get("/v1/auth/methods")
        expect_status(r, 200, "/v1/auth/methods")
        j = r.json()
        expect(j.get("password") is True, f"password=true 기대: {j}")
        expect(j.get("passwordSignup") is True, f"passwordSignup=true 기대(PASSWORD_SIGNUP_CODE 설정 필요): {j}")
    R.run("auth.methods", methods)

    def register():
        bad = app_register(R, "e2ebad" + secrets.token_hex(3), code="wrong-code")
        expect_status(bad, 403, "틀린 가입 코드")
        v = R.http.post("/v1/auth/password/register", json_body={"username": "A!", "password": "x", "signupCode": a.signup_code})
        expect_status(v, 400, "잘못된 username/password 검증")
        r = app_register(R, user, pw, display="E2E 사용자")
        expect_status(r, 200, "가입")
        j = r.json()
        for k in ("accessToken", "refreshToken", "expiresIn", "isNewUser"):
            expect(k in j, f"AuthTokens 에 {k} 없음: {list(j)}")
        expect(j["isNewUser"] is True, "isNewUser=true 기대")
        R.ctx["app_access"], R.ctx["app_refresh"] = j["accessToken"], j["refreshToken"]
        dup = app_register(R, user, pw)
        expect_status(dup, 409, "중복 아이디")
    R.run("auth.password_register", register)

    def login():
        bad = R.http.post("/v1/auth/password/login", json_body={"username": user, "password": "wrong-password"})
        expect_status(bad, 401, "틀린 비밀번호")
        r = R.http.post("/v1/auth/password/login", json_body={"username": user.upper(), "password": pw})
        expect_status(r, 200, "로그인(아이디는 대소문자 무시)")
        j = r.json()
        expect(j["isNewUser"] is False, "로그인은 isNewUser=false")
        R.ctx["app_access"], R.ctx["app_refresh"] = j["accessToken"], j["refreshToken"]
    R.run("auth.password_login", login)

    def lockout():
        u = "e2elock" + secrets.token_hex(3)
        expect_status(app_register(R, u, pw), 200, "잠금 점검용 계정 가입")
        last = None
        for _ in range(6):
            last = R.http.request("POST", "/v1/auth/password/login", json_body={"username": u, "password": "nope-nope-1"}, retry429=False)
        expect(last.status == 429, f"5회 이상 연속 실패 뒤 429 기대, 실제 {last.status}")
        expect(last.h("retry-after"), "429 에 Retry-After 헤더 필요")
        R.ctx.setdefault("throwaway_users", []).append((u, pw))
    R.run("auth.password_lockout", lockout)

    def refresh():
        old = R.need("app_refresh")
        r = R.http.post("/v1/auth/refresh", json_body={"refreshToken": old})
        expect_status(r, 200, "토큰 갱신")
        j = r.json()
        expect(j["refreshToken"] != old, "리프레시 토큰이 회전되지 않음")
        R.ctx["app_access"], R.ctx["app_refresh"] = j["accessToken"], j["refreshToken"]
        # 회전된 옛 토큰 재사용은 거절돼야 한다(다른 계정으로 확인해 본 계정을 폐기하지 않는다)
        u = "e2ereuse" + secrets.token_hex(3)
        t = app_register(R, u, pw).json()
        r1 = R.http.post("/v1/auth/refresh", json_body={"refreshToken": t["refreshToken"]})
        expect_status(r1, 200, "재사용 점검: 첫 갱신")
        # 회전 직후(유예 시간 REFRESH_REUSE_GRACE_SEC) 같은 토큰의 재시도는 네트워크 재시도로 보고 받아 준다.
        # 유예가 지난 뒤의 재사용 거절은 security.refresh_reuse_detected_after_grace 에서 확인한다
        r2 = R.http.post("/v1/auth/refresh", json_body={"refreshToken": t["refreshToken"]})
        expect(r2.status in (200, 401), f"재사용 점검: 유예 안 재시도는 200(유예) 또는 401 이어야 함: {r2.status}")
        R.ctx["reuse_app"] = (t["refreshToken"], u, pw)
        R.ctx.setdefault("throwaway_users", []).append((u, pw))
    R.run("auth.refresh_rotation", refresh)

    def me():
        r = api(R, "GET", "/v1/me", R.need("app_access"))
        expect_status(r, 200, "/v1/me")
        j = r.json()
        expect(j["email"] == f"{user}@password.local", f"email={j['email']}")
        R.ctx["user_id"] = j["id"]
        expect(sorted(j["consentsRequired"]) == ["HEALTH_DATA", "PRIVACY", "TERMS"], f"새 계정은 동의 3종이 필요: {j['consentsRequired']}")
        r = api(R, "GET", "/v1/me", "garbage")
        expect_status(r, 401, "엉터리 토큰으로 /v1/me")
    R.run("auth.me", me)

    def consent():
        # 앱과 똑같이: 앱에 하드코딩된 consentVersion 으로 3종을 순서대로 POST → /v1/me 에 남은 동의가 없어야 한다
        ver, src = detect_consent_version(a)
        expect(ver, "앱의 consentVersion 을 알 수 없음(--consent-version 지정 또는 저장소 체크아웃 필요)")
        tok = R.need("app_access")
        for kind in ("TERMS", "PRIVACY", "HEALTH_DATA"):
            r = api(R, "POST", "/v1/me/consents", tok, {"kind": kind, "version": ver, "granted": True})
            expect_status(r, 201, f"동의 {kind}")
        j = api(R, "GET", "/v1/me", tok).json()
        expect(j["consentsRequired"] == [],
               f"앱이 보내는 동의 버전({ver}, 출처 {src})을 서버가 현재 버전으로 인정하지 않음: consentsRequired={j['consentsRequired']}")
        got = api(R, "GET", "/v1/me/consents", tok).json()
        expect(len(got) == 3 and all(c["granted"] for c in got), f"/v1/me/consents={got}")
        bad = api(R, "POST", "/v1/me/consents", tok, {"kind": "NOPE", "version": ver, "granted": True})
        expect_status(bad, 400, "알 수 없는 동의 종류")
        return f"앱 버전 {ver}"
    R.run("consent.app_version_accepted_by_server", consent)

    def consent_sync():
        app_v, _ = detect_consent_version(a)
        srv_v = server_consent_version()
        if app_v is None or srv_v is None:
            return "소스가 없어 건너뜀"
        expect(app_v == srv_v, f"앱 consentVersion({app_v}) != 서버 CURRENT_CONSENT_VERSION({srv_v})")
    R.run("consent.app_and_server_constants_match", consent_sync)

    def stale_consent():
        # 옛 버전으로 동의한 사용자는 다시 동의해야 한다
        u = "e2eold" + secrets.token_hex(3)
        t = app_register(R, u, pw).json()["accessToken"]
        for kind in ("TERMS", "PRIVACY", "HEALTH_DATA"):
            api(R, "POST", "/v1/me/consents", t, {"kind": kind, "version": "1999-01-01", "granted": True})
        j = api(R, "GET", "/v1/me", t).json()
        expect(len(j["consentsRequired"]) == 3, f"옛 버전 동의는 무효여야 함: {j['consentsRequired']}")
        R.ctx.setdefault("throwaway_users", []).append((u, pw))
    R.run("consent.stale_version_requires_reconsent", stale_consent)


def plan_to_session(plan, tz="Asia/Seoul", instance_id=None, started=None):
    """계획(PlannedWorkout)을 전부 수행한 세션 JSON 으로 만든다(앱이 운동을 마치고 저장하는 모양)."""
    started = started or datetime.now(timezone.utc) - timedelta(hours=1)
    t = started
    exs = []
    for ei, e in enumerate(plan["exercises"]):
        sets = []
        for si, s in enumerate(e["sets"]):
            t = t + timedelta(minutes=3)
            sets.append({"id": str(uuid.uuid4()), "position": si, "isWarmup": s.get("isWarmup", False),
                         "weightKg": s["targetWeightKg"], "reps": s["targetReps"],
                         "completedAt": t.strftime("%Y-%m-%dT%H:%M:%S.000Z"),
                         "plannedSetKey": s["plannedSetKey"], "targetReps": s["targetReps"],
                         "targetWeightKg": s["targetWeightKg"], "isAmrap": s["isAmrap"]})
        exs.append({"id": str(uuid.uuid4()), "exerciseId": e["exerciseId"], "position": ei, "liftKey": e["key"],
                    "accessory": e["accessory"], "sets": sets})
    return {"id": str(uuid.uuid4()), "startedAt": started.strftime("%Y-%m-%dT%H:%M:%S.000Z"),
            "endedAt": t.strftime("%Y-%m-%dT%H:%M:%S.000Z"), "tz": tz, "exercises": exs,
            "programInstanceId": instance_id, "planSeq": plan["planSeq"], "planDayKey": plan["dayKey"]}


def c_app_flow(R):
    tok = lambda: R.need("app_access")  # noqa: E731

    def programs():
        r = api(R, "GET", "/v1/programs?source=TEMPLATE", tok())
        expect_status(r, 200, "프로그램 목록")
        lst = r.json()
        sl = [p for p in lst if p.get("templateKey") == "stronglifts-5x5"]
        expect(sl, f"템플릿 stronglifts-5x5 가 목록에 없음: {[p.get('templateKey') for p in lst]}")
        R.ctx["program_id"] = sl[0]["id"]
        ex = api(R, "GET", "/v1/exercises", tok())
        expect_status(ex, 200, "종목 목록")
        expect(len(ex.json()) >= 10, "기본 종목이 거의 없음")
    R.run("app.list_programs_and_exercises", programs)

    def start():
        pid = R.need("program_id")
        iid = str(uuid.uuid4())
        body = {"id": iid, "programId": pid, "startDate": datetime.now().strftime("%Y-%m-%d"), "tz": "Asia/Seoul",
                "tm": {}, "working": {"squat": 100, "bench": 60, "row": 50, "ohp": 40, "deadlift": 120}}
        r = api(R, "POST", "/v1/program-instances", tok(), body)
        expect_status(r, 201, "프로그램 시작")
        j = r.json()
        expect(j["status"] == "ACTIVE" and j["next"]["planSeq"] == 1, f"시작 직후 상태 이상: {j.get('status')} next={j.get('next', {}).get('planSeq')}")
        R.ctx["instance_id"] = iid
        lst = api(R, "GET", "/v1/program-instances?status=ACTIVE", tok()).json()
        expect(any(i["id"] == iid for i in lst), "진행 중 목록에 방금 시작한 인스턴스가 없음")
    R.run("app.start_program_instance", start)

    def plan():
        iid = R.need("instance_id")
        r = api(R, "GET", f"/v1/program-instances/{iid}/plan?count=3", tok())
        expect_status(r, 200, "계획")
        p = r.json()
        expect(len(p) == 3 and p[0]["planSeq"] == 1, f"계획 3개 기대: {[x['planSeq'] for x in p]}")
        expect(p[0]["exercises"] and p[0]["exercises"][0]["sets"], "계획에 종목/세트가 없음")
        R.ctx["plan0"] = p[0]
        R.ctx["squat_id"] = next(e["exerciseId"] for e in p[0]["exercises"] if e["key"] == "squat")
    R.run("app.get_plan", plan)

    def record_session():
        plan0, iid = R.need("plan0", "instance_id")
        s = plan_to_session(plan0, instance_id=iid)
        r = api(R, "PUT", f"/v1/sessions/{s['id']}", tok(), s)
        expect_status(r, (200, 201), "세션 저장(PUT /v1/sessions/{id})")
        saved = r.json()
        expect(len(saved["exercises"]) == len(s["exercises"]), "저장된 세션의 종목 수가 다름")
        R.ctx["session_id"] = s["id"]
        inst = api(R, "GET", f"/v1/program-instances/{iid}", tok()).json()
        expect(inst["next"]["planSeq"] == 2, f"세션 기록 뒤 다음 회차가 2 가 아님: {inst['next']['planSeq']}")
        expect(inst["state"]["working"]["squat"] > 100, f"모든 세트 성공 뒤 스쿼트 작업 무게가 오르지 않음: {inst['state']['working']}")
        return f"스쿼트 100 → {inst['state']['working']['squat']}"
    R.run("app.record_session_put_and_progression", record_session)

    def sync_flow():
        # 오프라인으로 쌓은 운동을 sync push 로 올린다(앱 동기화)
        squat = R.need("squat_id")
        now = datetime.now(timezone.utc)
        ts = lambda d=0: (now + timedelta(seconds=d)).strftime("%Y-%m-%dT%H:%M:%S.000Z")  # noqa: E731
        sid, seid, set1, set2, bid = (str(uuid.uuid4()) for _ in range(5))
        changes = [
            {"entity": "workout_session", "id": sid, "op": "UPSERT", "clientUpdatedAt": ts(0),
             "payload": {"startedAt": ts(-3600 * 5), "endedAt": ts(-3600 * 5 + 1800), "tz": "Asia/Seoul", "note": "e2e sync"}},
            {"entity": "session_exercise", "id": seid, "op": "UPSERT", "parentId": sid, "clientUpdatedAt": ts(1),
             "payload": {"exerciseId": squat, "position": 0}},
            {"entity": "workout_set", "id": set1, "op": "UPSERT", "parentId": seid, "clientUpdatedAt": ts(2),
             "payload": {"position": 0, "weightKg": 90.0, "reps": 8, "completedAt": ts(-3600 * 5 + 300)}},
            {"entity": "workout_set", "id": set2, "op": "UPSERT", "parentId": seid, "clientUpdatedAt": ts(3),
             "payload": {"position": 1, "weightKg": 92.5, "reps": 6, "completedAt": ts(-3600 * 5 + 600)}},
            {"entity": "body_measurement", "id": bid, "op": "UPSERT", "clientUpdatedAt": ts(4),
             "payload": {"measuredAt": ts(-60), "weightKg": 80.5}},
        ]
        r = api(R, "POST", "/v1/sync/push", tok(), {"changes": changes})
        expect_status(r, 200, "sync push")
        res = r.json()["results"]
        expect(len(res) == 5 and all(x["status"] == "applied" for x in res), f"push 결과: {[(x['id'][:8], x['status'], x.get('code')) for x in res]}")
        r = api(R, "POST", "/v1/sync/push", tok(), {"changes": changes})
        expect(all(x["status"] == "applied" for x in r.json()["results"]), "같은 push 를 다시 보내도 멱등이어야 함")
        pulled, since = {}, 0
        for _ in range(20):
            p = api(R, "GET", f"/v1/sync/pull?since={since}", tok())
            expect_status(p, 200, "sync pull")
            pj = p.json()
            for c in pj["changes"]:
                pulled[c["id"]] = c
            since = pj["nextSince"]
            if not pj["hasMore"]:
                break
        for what, i in (("앱이 PUT 한 세션", R.need("session_id")), ("push 한 세션", sid), ("push 한 세트", set1), ("체중", bid)):
            expect(i in pulled, f"sync pull(since=0)에 {what}({i[:8]})가 없음")
        R.ctx["sync_session_id"], R.ctx["body_id"] = sid, bid
    R.run("app.sync_push_then_pull", sync_flow)

    def read_back():
        sid = R.need("session_id")
        l = api(R, "GET", "/v1/sessions?limit=20", tok())
        expect_status(l, 200, "세션 목록")
        ids = [s["id"] for s in l.json()]
        expect(sid in ids and R.need("sync_session_id") in ids, f"세션 목록에 기록한 세션이 없음: {ids}")
        g = api(R, "GET", f"/v1/sessions/{sid}", tok())
        expect_status(g, 200, "세션 상세")
        expect(g.json()["planSeq"] == 1, "세션의 planSeq 가 유지되지 않음")
        last = api(R, "GET", f"/v1/exercises/{R.need('squat_id')}/last", tok())
        expect(last.status in (200, 204), f"/exercises/{{id}}/last: {last.status}")
    R.run("app.sessions_list_and_get", read_back)

    def stats():
        squat = R.need("squat_id")
        rec = api(R, "GET", f"/v1/exercises/{squat}/records", tok())
        expect_status(rec, 200, "records")
        rj = rec.json()
        expect(rj.get("bestWeight") and rj["bestWeight"]["weightKg"] >= 100, f"records.bestWeight 에 기록한 100kg 이 없음: {rj.get('bestWeight')}")
        pr = api(R, "GET", f"/v1/exercises/{squat}/progress", tok())
        expect_status(pr, 200, "progress")
        pj = pr.json()
        expect(len(pj["points"]) >= 1, f"progress.points 가 비어 있음: {pj}")
        cmp = api(R, "GET", f"/v1/sessions/{R.need('session_id')}/comparison", tok())
        expect_status(cmp, 200, "comparison")
    R.run("app.stats_records_progress", stats)

    def misc():
        t = tok()
        expect_status(api(R, "GET", "/v1/me/settings", t), 200, "settings")
        s = api(R, "PUT", "/v1/me/settings", t, {"weightUnit": "KG", "defaultRestSec": 120})
        expect_status(s, 200, "settings 저장")
        b = api(R, "GET", "/v1/body/measurements", t)
        expect_status(b, 200, "체중 목록")
        expect(any(m["id"] == R.need("body_id") for m in b.json()), "sync 로 올린 체중이 /v1/body/measurements 에 없음")
        expect_status(api(R, "GET", "/v1/deletion-requests/count", t), 200, "삭제 요청 개수")
        expect_status(api(R, "GET", "/v1/imports", t), 200, "가져오기 기록")
        mi = api(R, "GET", "/v1/mcp-info", t)
        expect_status(mi, 200, "mcp-info")
        expect(mi.json()["mcpUrl"] == R.public + "/mcp", f"/v1/mcp-info mcpUrl={mi.json()['mcpUrl']} 기대 {R.public}/mcp")
        ex = api(R, "GET", "/v1/export.json", t, timeout=120)
        expect_status(ex, 200, "export.json")
        sch = R.http.get("/v1/public/schema/import.json")
        expect_status(sch, 200, "공개 import 스키마")
    R.run("app.settings_body_export_mcpinfo", misc)


# =============================================================================================
# 점검: OAuth 등록·흐름
# =============================================================================================
def c_oauth(R):
    user, pw = R.need("username", "password")

    def reg_variants():
        cases = [
            ("ChatGPT(client_secret_post)", {"client_name": "ChatGPT", "redirect_uris": [CHATGPT_REDIRECT],
                                            "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"],
                                            "token_endpoint_auth_method": "client_secret_post"}, "client_secret_post"),
            ("ChatGPT(none)", {"client_name": "ChatGPT", "redirect_uris": [CHATGPT_REDIRECT],
                               "grant_types": ["authorization_code", "refresh_token"], "token_endpoint_auth_method": "none"}, "none"),
            ("ChatGPT(scope=openid email 같은 모르는 범위)", {"client_name": "ChatGPT", "redirect_uris": [CHATGPT_REDIRECT],
                                                    "token_endpoint_auth_method": "client_secret_post", "scope": "openid email profile offline_access"}, "client_secret_post"),
            ("ChatGPT(scope=fitlog.read fitlog.write)", {"client_name": "ChatGPT", "redirect_uris": [CHATGPT_REDIRECT],
                                                         "scope": "fitlog.read fitlog.write", "token_endpoint_auth_method": "client_secret_basic"}, "client_secret_basic"),
            ("Claude(none)", {"client_name": "Claude", "redirect_uris": [CLAUDE_REDIRECT], "token_endpoint_auth_method": "none",
                              "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"]}, "none"),
            ("client_name 없음", {"redirect_uris": [CLAUDE_REDIRECT]}, "none"),
            ("localhost http redirect(Inspector/Gemini CLI)", {"client_name": "Inspector", "redirect_uris": ["http://localhost:6274/oauth/callback"],
                                                              "token_endpoint_auth_method": "none"}, "none"),
            ("redirect_uris 여러 개 + 알 수 없는 필드", {"client_name": "X", "redirect_uris": [CHATGPT_REDIRECT, CLAUDE_REDIRECT],
                                                    "application_type": "web", "contacts": ["a@b.c"], "logo_uri": "https://x.example/l.png",
                                                    "software_id": "abc", "jwks_uri": "https://x.example/jwks"}, "none"),
        ]
        for label, payload, want_method in cases:
            r = oauth_register(R, payload)
            expect(r.status in (200, 201), f"등록 거절됨 [{label}]: HTTP {r.status} {r.text[:300]}")
            j = r.json()
            expect(j.get("client_id"), f"[{label}] client_id 없음")
            expect(j.get("redirect_uris") == payload["redirect_uris"], f"[{label}] redirect_uris 에코 불일치: {j.get('redirect_uris')}")
            expect(j.get("token_endpoint_auth_method") == want_method, f"[{label}] token_endpoint_auth_method={j.get('token_endpoint_auth_method')} 기대 {want_method}")
            if want_method != "none":
                expect(j.get("client_secret"), f"[{label}] {want_method} 인데 client_secret 이 없음")
        return f"{len(cases)}가지 페이로드"
    R.run("oauth.register_chatgpt_claude_variants", reg_variants)

    def reg_bad():
        for label, payload in (("http(비 localhost) redirect", {"redirect_uris": ["http://evil.example/cb"]}),
                               ("redirect_uris 없음", {"client_name": "x"}),
                               ("fragment redirect", {"redirect_uris": ["https://a.example/cb#x"]}),
                               ("javascript: redirect", {"redirect_uris": ["javascript:alert(1)"]})):
            r = oauth_register(R, payload)
            expect(r.status == 400, f"[{label}] 400 기대, 실제 {r.status}: {r.text[:200]}")
            expect(r.json().get("error") in ("invalid_redirect_uri", "invalid_client_metadata"), f"[{label}] error={r.text[:200]}")
        r = R.http.post("/oauth/register", raw="not json", headers={"Content-Type": "application/json"})
        expect(r.status == 400, f"깨진 JSON 은 400 기대, 실제 {r.status}")
    R.run("oauth.register_rejects_bad_input", reg_bad)

    def authz_errors():
        r = oauth_register(R, {"client_name": "E", "redirect_uris": [CHATGPT_REDIRECT]})
        cid = r.json()["client_id"]
        _, ch = new_pkce()
        base = {"response_type": "code", "client_id": cid, "redirect_uri": CHATGPT_REDIRECT, "state": "s1"}

        def az(extra, drop=()):
            p = {**base, **extra}
            for k in drop:
                p.pop(k, None)
            return R.http.get("/oauth/authorize?" + urllib.parse.urlencode(p))
        nopk = az({}, drop=())
        expect(nopk.status in (302, 303) and "error=invalid_request" in nopk.h("location", ""), f"PKCE 없는 요청은 invalid_request 리다이렉트: {nopk.status} {nopk.h('location')}")
        badm = az({"code_challenge": ch, "code_challenge_method": "plain"})
        expect(badm.status in (302, 303) and "error=invalid_request" in badm.h("location", ""), f"plain PKCE 거절 기대: {badm.status} {badm.h('location')}")
        badres = az({"code_challenge": ch, "code_challenge_method": "S256", "resource": "https://other.example/mcp"})
        expect(badres.status in (302, 303) and "invalid_target" in badres.h("location", ""), f"잘못된 resource → invalid_target 기대: {badres.status} {badres.h('location')}")
        badru = az({"code_challenge": ch, "code_challenge_method": "S256", "redirect_uri": "https://evil.example/cb"})
        expect(badru.status == 400 and not badru.h("location"), f"등록 안 된 redirect_uri 는 리다이렉트 없이 400: {badru.status} {badru.h('location')}")
        badc = az({"code_challenge": ch, "code_challenge_method": "S256", "client_id": "nope"})
        expect(badc.status == 400, f"모르는 client_id 는 400: {badc.status}")
    R.run("oauth.authorize_validation", authz_errors)

    def login_wrong_password():
        r = oauth_register(R, {"client_name": "E", "redirect_uris": [CHATGPT_REDIRECT]})
        cid = r.json()["client_id"]
        _, ch = new_pkce()
        b = Http(R.args.base_url)
        page = b.get("/oauth/authorize?" + urllib.parse.urlencode({
            "response_type": "code", "client_id": cid, "redirect_uri": CHATGPT_REDIRECT, "code_challenge": ch,
            "code_challenge_method": "S256", "state": "x"}), use_cookies=True)
        form = parse_forms(page.text).forms[0]
        data = {i["name"]: i["value"] for i in form["inputs"] if i["name"] and i["type"] == "hidden"}
        data.update({"username": user, "password": "totally-wrong"})
        r2 = b.post(form["action"], form=data, use_cookies=True)
        expect(r2.status == 401, f"틀린 비밀번호는 로그인 페이지 다시(401) 기대, 실제 {r2.status}")
        expect(not r2.h("location"), "틀린 비밀번호인데 리다이렉트됨")
    R.run("oauth.login_form_rejects_wrong_password", login_wrong_password)

    def flows():
        # A: ChatGPT 식(client_secret_post, resource 지정). 재시작 뒤 확인용으로 상태 파일에 저장한다
        a = oauth_connect(R, {"client_name": "ChatGPT", "redirect_uris": [CHATGPT_REDIRECT],
                              "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"],
                              "token_endpoint_auth_method": "client_secret_post"},
                          "client_secret_post", user, pw, CHATGPT_REDIRECT, resource=R.public + "/mcp",
                          scope="fitlog.read fitlog.write")
        expect("fitlog.write" in a["scope"], f"쓰기 허용했는데 scope={a['scope']}")
        R.ctx["mcp_a"] = a
        # B: Claude 식(none, resource 없음)
        b = oauth_connect(R, {"client_name": "Claude", "redirect_uris": [CLAUDE_REDIRECT], "token_endpoint_auth_method": "none"},
                          "none", user, pw, CLAUDE_REDIRECT)
        R.ctx["mcp_b"] = b
        # C: client_secret_basic 으로 토큰 교환
        c = oauth_connect(R, {"client_name": "Basic", "redirect_uris": [CHATGPT_REDIRECT], "token_endpoint_auth_method": "client_secret_basic"},
                          "client_secret_basic", user, pw, CHATGPT_REDIRECT)
        R.ctx["mcp_c"] = c
        # D: 읽기만 허용한 연결
        d = oauth_connect(R, {"client_name": "ReadOnly", "redirect_uris": [CLAUDE_REDIRECT], "token_endpoint_auth_method": "none"},
                          "none", user, pw, CLAUDE_REDIRECT, allow_write=False)
        expect("fitlog.write" not in d["scope"], f"읽기만 허용했는데 scope={d['scope']}")
        R.ctx["mcp_d"] = d
    R.run("oauth.full_flows(chatgpt_post/claude_none/basic/readonly)", flows)

    def write_box():
        expect(not R.ctx.get("write_checkbox_outside_form"),
               "동의 페이지의 '기록 추가·수정 허용' 체크박스(name=write)가 <form> 밖에 있어 브라우저가 제출하지 않음 → "
               "사용자가 허용해도 연결은 항상 fitlog.read 만 받아 쓰기 도구가 전부 '권한 없음'")
    R.run("oauth.consent_write_checkbox_is_inside_form", write_box)

    def code_rules():
        c = R.need("mcp_c")
        # 같은 코드를 다시 쓰면 invalid_grant (그리고 그 연결의 토큰이 폐기됨 — 그래서 C 연결로 확인)
        r = token_request(R, {"grant_type": "authorization_code", "code": c["code"], "redirect_uri": c["redirect_uri"],
                              "code_verifier": c["verifier"]}, c["auth_method"], c["client_id"], c["client_secret"])
        expect(r.status == 400 and r.json().get("error") == "invalid_grant", f"코드 재사용 → invalid_grant 기대: {r.status} {r.text[:200]}")
        # 틀린 code_verifier
        a = R.need("mcp_a")
        v, ch = new_pkce()
        q, loc, st, _ = oauth_login_and_consent(R, a["client_id"], a["redirect_uri"], user, pw, challenge=ch)
        r = token_request(R, {"grant_type": "authorization_code", "code": q["code"], "redirect_uri": a["redirect_uri"],
                              "code_verifier": new_pkce()[0]}, "client_secret_post", a["client_id"], a["client_secret"])
        expect(r.status == 400 and r.json().get("error") == "invalid_grant", f"틀린 code_verifier → invalid_grant 기대: {r.status} {r.text[:200]}")
        r = token_request(R, {"grant_type": "password", "username": "x", "password": "y"}, "none", a["client_id"])
        expect(r.status == 400 and r.json().get("error") == "unsupported_grant_type", f"unsupported_grant_type 기대: {r.status} {r.text[:200]}")
    R.run("oauth.token_endpoint_rules", code_rules)

    def refresh():
        c = R.need("mcp_c")
        r = token_request(R, {"grant_type": "refresh_token", "refresh_token": c["refresh"]}, c["auth_method"], c["client_id"], c["client_secret"])
        c_d = None
        # 코드 재사용 점검에서 C 연결 토큰이 폐기됐을 수 있으므로, 새 연결(E)로 회전·재사용을 확인한다
        e = oauth_connect(R, {"client_name": "Rot", "redirect_uris": [CLAUDE_REDIRECT], "token_endpoint_auth_method": "none"},
                          "none", user, pw, CLAUDE_REDIRECT)
        r1 = token_request(R, {"grant_type": "refresh_token", "refresh_token": e["refresh"]}, "none", e["client_id"])
        expect_status(r1, 200, "refresh_token 교환")
        j = r1.json()
        expect(j["refresh_token"] != e["refresh"] and j["access_token"] != e["access"], "리프레시 회전(새 토큰) 안 됨")
        expect(mcp_rpc(R, j["access_token"], "initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "t", "version": "1"}}).status == 200,
               "갱신된 액세스 토큰으로 MCP 호출 실패")
        R.ctx["reuse_oauth"] = (e["refresh"], e["client_id"])
        _ = c_d, r
    R.run("oauth.refresh_rotation_and_reuse_detection", refresh)


def c_reuse_after_grace(R):
    """유예 시간(60초)이 지난 뒤 회전된 옛 리프레시 토큰을 쓰면 거절돼야 한다(탈취 대응)."""
    def f():
        old_app, _, _ = R.need("reuse_app")
        old_oauth, cid = R.need("reuse_oauth")
        wait = R.args.reuse_grace_wait
        if wait > 0:
            time.sleep(wait)
        r = R.http.post("/v1/auth/refresh", json_body={"refreshToken": old_app})
        expect(r.status == 401, f"유예 지난 뒤 앱 옛 리프레시 토큰 재사용은 401 기대, 실제 {r.status}")
        r = token_request(R, {"grant_type": "refresh_token", "refresh_token": old_oauth}, "none", cid)
        expect(r.status == 400 and r.json().get("error") == "invalid_grant", f"유예 지난 뒤 OAuth 옛 리프레시 토큰 재사용은 invalid_grant 기대: {r.status} {r.text[:200]}")
    R.run("security.refresh_reuse_detected_after_grace", f)


# =============================================================================================
# 점검: MCP 프로토콜 / 도구
# =============================================================================================
def mcp_protocol(R):
    a = R.need("mcp_a")

    def init_versions():
        for ver in ("2025-06-18", "2025-03-26"):
            sid, res = mcp_init(R, a["access"], ver)
            expect(res["protocolVersion"] == ver, f"initialize({ver}) 응답 protocolVersion={res['protocolVersion']}")
            expect("tools" in res["capabilities"], f"capabilities 에 tools 없음: {res['capabilities']}")
            expect(res["serverInfo"]["name"], "serverInfo.name 없음")
            expect(res.get("instructions"), "instructions 없음")
            tools = mcp_list_tools(R, a["access"], sid, ver)
            expect(len(tools) >= len(EXPECTED_TOOLS), f"{ver} 세션에서 tools/list 가 {len(tools)}개")
        sid, _ = mcp_init(R, a["access"], "2025-06-18")
        R.ctx["mcp_sid"] = sid
        # 새 세션을 한 번 더 열어 둔다: 서버가 모르는 프로토콜 버전을 주면 최신으로 협상해야 한다
        r = mcp_rpc(R, a["access"], "initialize", {"protocolVersion": "2099-01-01", "capabilities": {}, "clientInfo": {"name": "t", "version": "1"}})
        expect(r.json()["result"]["protocolVersion"] in ("2025-06-18", "2025-03-26"), "모르는 버전에 대한 협상 결과 이상")
    R.run("mcp.initialize_both_protocol_versions", init_versions)

    def list_tools():
        sid = R.need("mcp_sid")
        tools = mcp_list_tools(R, a["access"], sid)
        names = [t["name"] for t in tools]
        R.ctx["_tools_by_name"] = {t["name"]: t for t in tools}
        missing = [n for n in EXPECTED_TOOLS if n not in names]
        extra = [n for n in names if n not in EXPECTED_TOOLS]
        dup = sorted({n for n in names if names.count(n) > 1})
        expect(not missing and not extra and not dup,
               f"tools/list 이름이 기대와 다름 — 빠진 도구: {missing or '없음'}, 기대에 없는 도구: {extra or '없음'}, 중복: {dup or '없음'} "
               f"(서버 {len(names)}개 / 기대 {len(EXPECTED_TOOLS)}개). 도구를 바꿨다면 e2e/run.py 의 EXPECTED_*_TOOLS 와 CALL_CASES 도 고칠 것")
        for t in tools:
            expect(t.get("description") and t.get("inputSchema", {}).get("type") == "object", f"{t['name']}: description/inputSchema 형식 이상")
            expect("outputSchema" in t, f"{t['name']}: outputSchema 선언 없음")
        return f"{len(names)}개"
    R.run("mcp.tools_list_exact", list_tools)

    def source_diff():
        src = server_tool_names()
        if src is None:
            return "서버 소스가 없어 건너뜀"
        missing = [n for n in src if n not in EXPECTED_TOOLS]
        extra = [n for n in EXPECTED_TOOLS if n not in src]
        expect(not missing and not extra, f"서버 소스의 도구와 e2e 기대 목록이 다름 — e2e 에 없는 도구: {missing or '없음'}, 소스에 없는 도구: {extra or '없음'}")
        return f"소스 {len(src)}개"
    R.run("mcp.tool_list_matches_server_source", source_diff)

    def session_edge():
        sid = R.need("mcp_sid")
        t = a["access"]
        r = mcp_rpc(R, t, "tools/list", {}, sid="not-a-valid-session")
        expect(r.status == 200 and "tools" in r.json().get("result", {}), f"모르는 세션 ID 도 처리(200) 기대, 실제 {r.status}: {r.text[:200]}")
        r = mcp_rpc(R, t, "tools/list", {})
        expect(r.status == 200 and "tools" in r.json().get("result", {}), f"세션 헤더 없는 tools/list 도 처리(200) 기대, 실제 {r.status}")
        r = mcp_rpc(R, t, "ping", {}, sid=sid)
        expect(r.status == 200 and r.json().get("result") == {}, f"ping: {r.status} {r.text[:100]}")
        r = mcp_rpc(R, t, "no/such/method", {}, sid=sid)
        expect(r.status == 200 and r.json().get("error", {}).get("code") == -32601, f"없는 메서드는 -32601: {r.text[:200]}")
        r = R.http.post("/mcp", headers={"Authorization": f"Bearer {t}", "Mcp-Session-Id": sid}, raw="{not json")
        expect(r.status == 400 and r.json().get("error", {}).get("code") == -32700, f"깨진 JSON 은 400/-32700: {r.status} {r.text[:200]}")
        g = R.http.get("/mcp", headers={"Authorization": f"Bearer {t}", "Accept": "text/event-stream"})
        expect(g.status == 405, f"GET /mcp 는 405 기대, 실제 {g.status}")
        # 세션 닫기(DELETE) 뒤에도 같은 세션 ID 는 계속 처리된다(인증은 Bearer 토큰)
        s2, _ = mcp_init(R, t)
        d = R.http.request("DELETE", "/mcp", headers={"Authorization": f"Bearer {t}", "Mcp-Session-Id": s2})
        expect(d.status in (200, 204), f"DELETE /mcp 기대 200/204, 실제 {d.status}")
        r = mcp_rpc(R, t, "tools/list", {}, sid=s2)
        expect(r.status == 200 and "tools" in r.json().get("result", {}), f"닫은 세션도 처리(200) 기대, 실제 {r.status}")
    R.run("mcp.session_and_jsonrpc_edge_cases", session_edge)

    def trace():
        g = R.http.get("/health/mcp-trace")
        if g.status == 404:
            return "추적 꺼짐(404) - MCP_TRACE=true 또는 비밀번호 로그인 서버에서만 점검"
        expect(g.status == 200, f"/health/mcp-trace 기대 200, 실제 {g.status}")
        rows = g.json().get("entries", [])
        methods = {e.get("rpcMethod") for e in rows}
        expect({"initialize", "tools/list"} <= methods, f"추적에 initialize/tools/list 행이 없음: {sorted(m for m in methods if m)}")
        init = next(e for e in rows if e.get("rpcMethod") == "initialize")
        expect(init.get("client") and init.get("authenticated") is True, f"initialize 행에 client/authenticated 없음: {init}")
        txt = g.text
        expect(a["access"] not in txt, "추적 응답에 액세스 토큰이 들어 있음")
        return f"{len(rows)}행"
    R.run("mcp.trace_endpoint_shows_requests", trace)


def schema_bad_args(schema):
    """inputSchema 에서 '명백히 잘못된' 인자를 만든다: 필수가 있으면 비우고, 없으면 enum/정수/문자열 타입을 깬다."""
    props = schema.get("properties", {})
    req = schema.get("required", [])
    variants = []
    if req:
        variants.append(("필수 인자 누락", {}))
        p = props.get(req[0], {})
        variants.append((f"{req[0]} 타입 오류", {**{k: "x" for k in req[1:]}, req[0]: 12345 if p.get("type") != "integer" else "abc"}))
    for name, p in props.items():
        if "enum" in p:
            variants.append((f"{name} 에 허용 안 되는 enum 값", {**({k: "x" for k in req}), name: "__BOGUS__"}))
            break
    for name, p in props.items():
        if p.get("type") in ("integer", "number"):
            variants.append((f"{name} 에 숫자 아닌 값", {**({k: "x" for k in req}), name: "abc"}))
            break
    if not variants:
        variants.append(("arguments 가 객체가 아님", "not-an-object"))
    return variants


class CallCtx:
    """도구 호출 사례가 서로 만든 데이터를 이어 쓰기 위한 보관소"""
    pass


def build_call_cases(R, cc):
    """도구 이름 → 유효한 인자를 돌려주는 함수. 도구가 하나 늘면 여기에도 사례를 추가해야 한다(없으면 점검 실패)."""
    suffix = secrets.token_hex(3)
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    cases = {}
    cases["get_profile"] = lambda: {}
    cases["search_exercises"] = lambda: {"query": "스쿼트", "limit": 5}
    cases["list_programs"] = lambda: {"source": "TEMPLATE"}
    cases["get_program"] = lambda: {"templateKey": "stronglifts-5x5"}
    cases["validate_program"] = lambda: {"definition": cc.definition}
    cases["list_program_instances"] = lambda: {"status": "ACTIVE"}
    cases["get_plan"] = lambda: {"instanceId": cc.instance_id, "count": 2}
    cases["list_sessions"] = lambda: {"from": "2020-01-01", "to": "2099-12-31", "limit": 10}
    cases["get_session"] = lambda: {"id": cc.session_id}
    cases["get_exercise_records"] = lambda: {"exerciseId": cc.exercise_id}
    cases["get_exercise_progress"] = lambda: {"exerciseId": cc.exercise_id}
    cases["get_training_summary"] = lambda: {"from": (datetime.now(timezone.utc) - timedelta(days=90)).strftime("%Y-%m-%d"), "to": today}
    cases["get_body_measurements"] = lambda: {"from": "2020-01-01", "to": "2099-12-31"}
    cases["list_deletion_requests"] = lambda: {"status": "PENDING"}
    cases["search"] = lambda: {"query": "스쿼트"}
    cases["fetch"] = lambda: {"id": f"session:{cc.session_id}"}
    cases["import_bundle"] = lambda: {"bundle": {"schemaVersion": 1, "note": "e2e", "bodyMeasurements": [
        {"measuredAt": (datetime.now(timezone.utc) - timedelta(days=20)).strftime("%Y-%m-%dT%H:%M:%SZ"), "weightKg": 81.2}]}}
    cases["create_program"] = lambda: {"definition": cc.new_definition}
    cases["start_program"] = lambda: {"program": {"templateKey": "stronglifts-5x5"}, "startDate": today,
                                      "working": {"squat": 60, "bench": 40, "row": 40, "ohp": 30, "deadlift": 80}}
    cases["log_session"] = lambda: {"session": {
        "startedAt": (datetime.now(timezone.utc) - timedelta(days=10)).strftime("%Y-%m-%dT%H:%M:%SZ"), "tz": "Asia/Seoul",
        "exercises": [{"exercise": {"id": cc.exercise_id}, "sets": [{"weightKg": 110, "reps": 5}, {"weightKg": 110, "reps": 5, "rpe": 8}]}]}}
    cases["log_body_weight"] = lambda: {"measuredAt": (datetime.now(timezone.utc) - timedelta(days=30)).strftime("%Y-%m-%dT%H:%M:%SZ"), "weightKg": 79.9}
    cases["create_exercise"] = lambda: {"nameKo": f"E2E 케이블 컬 {suffix}", "nameEn": f"E2E Cable Curl {suffix}", "type": "MACHINE", "primaryMuscle": "BICEPS"}
    cases["adjust_program_instance"] = lambda: {"instanceId": cc.instance_id, "working": {"squat": 105}}
    tomorrow = (datetime.now(timezone.utc) + timedelta(days=1)).strftime("%Y-%m-%d")
    cases["schedule_workout"] = lambda: {"workout": {"plannedDate": tomorrow, "title": "E2E 하체", "items": [
        {"exercise": {"name": "스쿼트"}, "restSec": 180, "sets": [
            {"targetWeightKg": 80, "targetReps": 12},
            {"targetWeightKg": 100, "targetReps": 10, "targetRepsMax": 12, "targetRir": 3}]}]}}
    cases["list_scheduled_workouts"] = lambda: {"from": tomorrow, "to": tomorrow}
    cases["skip_scheduled_workout"] = lambda: {"id": cc.scheduled_id, "skipped": True}
    cases["request_deletion"] = lambda: {"entity": "session", "id": cc.session_id, "reason": "e2e 점검용 삭제 요청"}
    return cases


# 호출 순서: 데이터를 만드는 쓰기 도구를 먼저, 그 값을 읽는 조회 도구를 나중에
CALL_ORDER = ["get_profile", "search_exercises", "list_programs", "get_program", "validate_program", "create_program",
              "create_exercise", "start_program", "list_program_instances", "get_plan", "adjust_program_instance",
              "log_session", "log_body_weight", "import_bundle", "schedule_workout", "list_scheduled_workouts",
              "skip_scheduled_workout", "list_sessions", "get_session", "get_exercise_records",
              "get_exercise_progress", "get_training_summary", "get_body_measurements", "request_deletion", "list_deletion_requests", "search", "fetch"]


def mcp_tools(R):
    b = R.need("mcp_b")
    state = {}
    cc = CallCtx()
    tools = R.ctx.get("_tools_by_name") or {}

    def prep():
        sid, _ = mcp_init(R, b["access"])
        R.ctx["mcp_b_sid"] = sid
        listed = mcp_list_tools(R, b["access"], sid)
        R.ctx["_tools_by_name"] = {t["name"]: t for t in listed}
        # 앱 쪽 흐름에서 만든 데이터를 이어 쓴다
        cc.instance_id = R.need("instance_id")
        cc.session_id = R.need("session_id")
        cc.exercise_id = R.need("squat_id")
        defn = tool_ok(R, b["access"], sid, "get_program", {"templateKey": "stronglifts-5x5"})["program"]["definition"]
        cc.definition = defn
        nd = json.loads(json.dumps(defn))
        nd["name"] = f"E2E 프로그램 {secrets.token_hex(3)}"
        for k in ("id", "templateKey"):
            nd.pop(k, None)
        cc.new_definition = nd
    R.run("mcp.tools.prepare_context", prep)

    cases = build_call_cases(R, cc)

    def coverage():
        names = list((R.ctx.get("_tools_by_name") or {}).keys()) or EXPECTED_TOOLS
        no_case = [n for n in names if n not in cases or n not in CALL_ORDER]
        stale = [n for n in cases if n not in names]
        expect(not no_case, f"호출 사례(CALL_CASES/CALL_ORDER)가 없는 도구: {no_case} — 새 도구는 e2e 에 호출 사례를 추가해야 함")
        expect(not stale, f"서버에 없는데 호출 사례만 있는 도구: {stale}")
        # 사례의 인자가 inputSchema 필수 필드를 다 채우는지(스키마 기준) 확인은 호출 직전에 한다
    R.run("mcp.tools.every_tool_has_a_call_case", coverage)

    def make(name):
        def f():
            sid = R.need("mcp_b_sid")
            args = cases[name]()
            schema = (R.ctx["_tools_by_name"].get(name) or {}).get("inputSchema", {})
            missing_req = [k for k in schema.get("required", []) if k not in args]
            expect(not missing_req, f"e2e 호출 사례가 inputSchema 필수 인자 {missing_req} 를 빠뜨림")
            sc = tool_ok(R, b["access"], sid, name, args)
            if name == "create_exercise":
                expect(sc.get("status") == "SAVED", f"create_exercise status={sc.get('status')}: {json.dumps(sc, ensure_ascii=False)[:300]}")
            if name in ("create_program", "start_program", "log_session", "log_body_weight", "import_bundle"):
                expect(sc.get("status") == "SAVED", f"{name}: status={sc.get('status')} (SAVED 기대) {json.dumps(sc, ensure_ascii=False)[:400]}")
                expect(sc.get("importBatchId"), f"{name}: importBatchId 없음")
            if name == "schedule_workout":
                expect(sc.get("status") == "SAVED", f"schedule_workout status={sc.get('status')}: {json.dumps(sc, ensure_ascii=False)[:400]}")
                sw = sc.get("scheduledWorkouts") or []
                expect(sw and sw[0].get("id"), f"schedule_workout 응답에 scheduledWorkouts[0].id 없음: {json.dumps(sc, ensure_ascii=False)[:300]}")
                cc.scheduled_id = sw[0]["id"]
                # 완전히 같은 내용을 다시 보내면 멱등 재생(같은 묶음, created=false)
                again = tool_ok(R, b["access"], sid, name, args)
                expect(again.get("status") == "SAVED" and again.get("created") is False and again.get("importBatchId") == sc.get("importBatchId"),
                       f"같은 요청 재호출은 같은 묶음을 돌려주는 멱등 재생이어야 함: {json.dumps(again, ensure_ascii=False)[:300]}")
                # 같은 날짜+제목인데 내용이 다르면 중복 충돌로 저장하지 않는다
                other = json.loads(json.dumps(args))
                other["workout"]["items"][0]["sets"][0]["targetReps"] = 8
                dup = tool_ok(R, b["access"], sid, name, other)
                codes = [c.get("code") for c in dup.get("conflicts", [])]
                expect(dup.get("status") == "NEEDS_RESOLUTION" and "SCHEDULED_DUPLICATE" in codes,
                       f"같은 날짜+제목(내용 다름) 재호출은 NEEDS_RESOLUTION(SCHEDULED_DUPLICATE) 기대: {json.dumps(dup, ensure_ascii=False)[:300]}")
            if name == "list_scheduled_workouts":
                items = next((v for v in sc.values() if isinstance(v, list)), [])
                hit = [i for i in items if i.get("id") == cc.scheduled_id]
                expect(hit and hit[0].get("status") == "PLANNED", f"예정 운동 목록에 PLANNED 항목이 없음: {json.dumps(sc, ensure_ascii=False)[:300]}")
            if name == "skip_scheduled_workout":
                expect(json.dumps(sc).count("SKIPPED") >= 1, f"skip_scheduled_workout 결과에 SKIPPED 없음: {json.dumps(sc, ensure_ascii=False)[:300]}")
            if name == "list_sessions":
                expect(any(s.get("id") == cc.session_id for s in sc.get("sessions", sc.get("items", []))) or sc.get("count", 0) >= 1,
                       f"list_sessions 에 앱이 기록한 세션이 없음: {json.dumps(sc, ensure_ascii=False)[:300]}")
            if name == "get_session":
                expect(sc["session"]["id"] == cc.session_id, "get_session 이 다른 세션을 돌려줌")
            if name == "get_exercise_records":
                expect(sc["records"].get("bestWeight"), "get_exercise_records 에 bestWeight 없음")
            if name == "get_exercise_progress":
                expect(len(sc["progress"]["points"]) >= 1, "get_exercise_progress points 비어 있음")
            if name == "get_training_summary":
                expect(sc["sessionCount"] >= 1, f"훈련 요약 sessionCount={sc['sessionCount']}")
            if name == "get_body_measurements":
                expect(len(sc.get("measurements", sc.get("items", []))) >= 1, "체중 기록이 비어 있음")
            if name == "get_plan":
                expect(sc.get("plan") or sc.get("workouts") or sc.get("items") or sc, "get_plan 비어 있음")
            if name == "request_deletion":
                expect(sc["status"] == "PENDING", f"request_deletion status={sc['status']}")
            if name == "list_deletion_requests":
                expect(sc.get("count", 0) >= 1, "삭제 요청 목록에 방금 만든 요청이 없음")
            if name == "adjust_program_instance":
                expect(sc["instance"]["state"]["working"]["squat"] == 105, f"조정 결과: {sc['instance']['state']['working']}")
            state[name] = sc
        return f
    for n in CALL_ORDER:
        if n in cases:
            R.run(f"mcp.tool.{n}", make(n))

    # 읽기 전용 연결은 쓰기 도구를 못 쓴다
    def readonly():
        d = R.need("mcp_d")
        sid, _ = mcp_init(R, d["access"])
        tool_ok(R, d["access"], sid, "get_profile", {})
        r, j = mcp_call_tool(R, d["access"], sid, "log_body_weight", {"measuredAt": now_iso(-5), "weightKg": 80})
        expect(r.status == 200 and j["result"]["isError"] is True, f"읽기 전용 연결이 쓰기 도구를 실행함: {r.text[:300]}")
    R.run("mcp.readonly_connection_cannot_write", readonly)

    # 잘못된 인자 → 500 이 아니라 도구 오류(또는 JSON-RPC 파라미터 오류)
    # 호출 제한(토큰당 분당 60회, 쓰기 20회)에 걸리지 않도록 쓰기 도구 절반은 별도 연결(F)로 호출한다
    def f_conn():
        fc = oauth_connect(R, {"client_name": "BadArgs", "redirect_uris": [CLAUDE_REDIRECT], "token_endpoint_auth_method": "none"},
                           "none", R.need("username"), R.need("password"), CLAUDE_REDIRECT)
        fsid, _ = mcp_init(R, fc["access"])
        R.ctx["mcp_f"], R.ctx["mcp_f_sid"] = fc, fsid
    R.run("mcp.tool_bad_args.prepare_second_connection", f_conn)

    def make_bad(name):
        def f():
            use_f = name in ("create_exercise", "adjust_program_instance", "request_deletion", "log_body_weight", "skip_scheduled_workout")
            a = R.need("mcp_f" if use_f else "mcp_a")
            sid = R.need("mcp_f_sid" if use_f else "mcp_sid")
            schema = (R.ctx["_tools_by_name"].get(name) or {}).get("inputSchema", {})
            for label, bad in schema_bad_args(schema):
                r, j = mcp_call_tool(R, a["access"], sid, name, bad)
                expect(r.status == 200, f"{name} [{label}] HTTP {r.status} (200 + 도구 오류 기대): {r.text[:300]}")
                is_rpc_err = j is not None and "error" in j and j["error"].get("code") in (-32602, -32600)
                is_tool_err = j is not None and "result" in j and j["result"].get("isError") is True
                expect(is_rpc_err or is_tool_err, f"{name} [{label}] 잘못된 인자가 오류로 처리되지 않음: {r.text[:300]}")
                if is_tool_err:
                    expect(j["result"]["content"][0]["text"], f"{name} [{label}] 오류 메시지 비어 있음")
        return f
    for n in EXPECTED_TOOLS:
        R.run(f"mcp.tool_bad_args.{n}", make_bad(n))

    # 서버가 만든 데이터가 앱 REST 로도 보이는가(두 경로가 같은 DB 를 본다)
    def cross():
        t = R.need("app_access")
        conns = api(R, "GET", "/v1/me/ai-connections", t)
        expect_status(conns, 200, "AI 연결 목록")
        names = [c.get("clientName") or c.get("name") for c in conns.json()]
        expect(len(names) >= 3, f"앱의 AI 연결 목록에 연결이 {len(names)}개뿐: {names}")
        reqs = api(R, "GET", "/v1/deletion-requests?status=PENDING", t)
        expect_status(reqs, 200, "삭제 요청 목록")
        expect(len(reqs.json()) >= 1, "MCP 가 만든 삭제 요청이 앱에서 안 보임")
        ims = api(R, "GET", "/v1/imports", t).json()
        expect(len(ims) >= 1, "MCP 가 저장한 가져오기 묶음이 앱의 AI 기록에서 안 보임")
        exs = api(R, "GET", "/v1/exercises?q=E2E", t).json()
        expect(any("E2E" in e["nameKo"] for e in exs), "MCP 로 만든 종목이 앱에서 안 보임")
        sess = api(R, "GET", "/v1/sessions?limit=50", t).json()
        expect(any(s.get("source") not in (None, "APP") or s.get("importBatchId") for s in sess), "MCP 로 기록한 세션이 앱 세션 목록에서 안 보임")
    R.run("mcp.writes_visible_in_app_rest", cross)


# =============================================================================================
# before-restart 마무리: 상태 저장
# =============================================================================================
def finish_before(R):
    a = R.need("mcp_a")
    st = {
        "created_at": now_iso(), "base_url": R.args.base_url,
        "username": R.ctx["username"], "password": R.ctx["password"],
        "app_access": R.ctx["app_access"], "app_refresh": R.ctx["app_refresh"], "user_id": R.ctx.get("user_id"),
        "mcp_a": {k: a[k] for k in ("client_id", "client_secret", "redirect_uri", "auth_method", "access", "refresh", "scope", "resource")},
        "mcp_sid": R.ctx["mcp_sid"], "session_id": R.ctx.get("session_id"), "sync_session_id": R.ctx.get("sync_session_id"),
        "instance_id": R.ctx.get("instance_id"), "squat_id": R.ctx.get("squat_id"),
        "tool_count": len(R.ctx.get("_tools_by_name", {})) or len(EXPECTED_TOOLS),
        "tool_names": sorted((R.ctx.get("_tools_by_name") or {}).keys()),
    }
    save_state(R.args.state, st)
    print(f"  (상태 저장: {R.args.state})")


# =============================================================================================
# after-restart
# =============================================================================================
def after_restart(R):
    st = load_state(R.args.state)
    if not st:
        R.run("restart.state_file_present", lambda: expect(False, f"상태 파일이 없음: {R.args.state} (먼저 --phase before-restart 실행)"))
        return
    a = st["mcp_a"]
    user, pw = st["username"], st["password"]
    R.ctx.update({"username": user, "password": pw})

    def tools_survive():
        r = mcp_rpc(R, a["access"], "tools/list", {}, sid=st["mcp_sid"])
        expect(r.status == 200, f"재시작 뒤 같은 토큰+세션 ID 의 tools/list 가 HTTP {r.status} (404 면 세션이 메모리에만 있다는 뜻 — 클라이언트는 도구 0개로 봄): {r.text[:300]}")
        tools = r.json()["result"]["tools"]
        names = [t["name"] for t in tools]
        missing = [n for n in EXPECTED_TOOLS if n not in names]
        extra = [n for n in names if n not in EXPECTED_TOOLS]
        expect(not missing and not extra, f"재시작 뒤 tools/list 가 기대와 다름 — 빠짐 {missing}, 기대에 없음 {extra}")
        R.ctx["_tools_by_name"] = {t["name"]: t for t in tools}
        return f"{len(names)}개"
    R.run("restart.mcp_tools_list_same_token_and_session", tools_survive)

    def read_call():
        sc = tool_ok(R, a["access"], st["mcp_sid"], "get_session", {"id": st["session_id"]})
        expect(sc["session"]["id"] == st["session_id"], "재시작 전에 기록한 세션이 사라짐")
        sc = tool_ok(R, a["access"], st["mcp_sid"], "list_program_instances", {})
        expect(sc, "list_program_instances 응답 없음")
        tool_ok(R, a["access"], st["mcp_sid"], "get_profile", {})
    R.run("restart.mcp_read_tool_call_same_session", read_call)

    def write_call():
        sc = tool_ok(R, a["access"], st["mcp_sid"], "log_body_weight", {"measuredAt": now_iso(-60 * 24 * 40), "weightKg": 80.1})
        expect(sc["status"] == "SAVED", f"재시작 뒤 쓰기 도구 실패: {sc}")
    R.run("restart.mcp_write_tool_call_same_session", write_call)

    def new_init():
        sid, _ = mcp_init(R, a["access"])
        expect(len(mcp_list_tools(R, a["access"], sid)) >= len(EXPECTED_TOOLS), "재시작 뒤 새 세션의 tools/list 도구 수 부족")
    R.run("restart.mcp_new_session_initialize", new_init)

    def oauth_refresh():
        r = token_request(R, {"grant_type": "refresh_token", "refresh_token": a["refresh"]}, a["auth_method"], a["client_id"], a.get("client_secret"))
        expect_status(r, 200, "재시작 뒤 리프레시 토큰 교환")
        j = r.json()
        sid, _ = mcp_init(R, j["access_token"])
        expect(len(mcp_list_tools(R, j["access_token"], sid)) >= len(EXPECTED_TOOLS), "갱신된 토큰으로 tools/list 실패")
        # 옛 세션 ID 는 새 토큰에서도 같은 연결이므로 유효해야 한다(클라이언트는 토큰이 갱신돼도 세션을 유지한다)
        r2 = mcp_rpc(R, j["access_token"], "tools/list", {}, sid=st["mcp_sid"])
        expect(r2.status == 200, f"토큰 갱신 뒤 기존 Mcp-Session-Id 가 거절됨(HTTP {r2.status}) — 클라이언트가 세션을 잃는다")
    R.run("restart.oauth_refresh_token_still_works", oauth_refresh)

    def app_token():
        r = api(R, "GET", "/v1/me", st["app_access"])
        expect_status(r, 200, "재시작 전에 받은 앱 액세스 토큰")
        r = R.http.post("/v1/auth/refresh", json_body={"refreshToken": st["app_refresh"]})
        expect_status(r, 200, "재시작 전에 받은 앱 리프레시 토큰")
        j = r.json()
        me = api(R, "GET", "/v1/me", j["accessToken"]).json()
        expect(me["consentsRequired"] == [], f"재시작 뒤 동의 상태가 사라짐: {me['consentsRequired']}")
        R.ctx["app_access"] = j["accessToken"]
        s = api(R, "GET", f"/v1/sessions/{st['session_id']}", j["accessToken"])
        expect_status(s, 200, "재시작 전에 기록한 세션")
        l = R.http.post("/v1/auth/password/login", json_body={"username": user, "password": pw})
        expect_status(l, 200, "재시작 뒤 비밀번호 로그인")
    R.run("restart.app_tokens_and_data", app_token)

    def client_exists():
        # 등록해 둔 OAuth 클라이언트로 새 인가를 시작하면 로그인 페이지가 떠야 한다(등록이 메모리에만 있으면 400)
        _, ch = new_pkce()
        r = R.http.get("/oauth/authorize?" + urllib.parse.urlencode({
            "response_type": "code", "client_id": a["client_id"], "redirect_uri": a["redirect_uri"],
            "code_challenge": ch, "code_challenge_method": "S256", "state": "after"}))
        expect(r.status == 200, f"재시작 뒤 등록된 클라이언트의 /oauth/authorize 가 {r.status}: {r.text[:200]}")
        # 끝까지: 같은 client_id 로 새 코드를 받아 토큰까지 교환
        conn = oauth_connect(R, None, a["auth_method"], user, pw, a["redirect_uri"], reuse_client=(a["client_id"], a.get("client_secret")),
                             resource=a.get("resource"))
        sid, _ = mcp_init(R, conn["access"])
        expect(len(mcp_list_tools(R, conn["access"], sid)) >= len(EXPECTED_TOOLS), "재시작 뒤 새 연결의 tools/list 실패")
    R.run("restart.registered_oauth_client_still_exists", client_exists)

    def metadata_same():
        c_h = c_metadata  # noqa: F841
        r = R.http.get("/.well-known/oauth-protected-resource")
        expect(r.json()["resource"] == R.public + "/mcp", "재시작 뒤 메타데이터 resource 변경")
    R.run("restart.metadata_unchanged", metadata_same)


# =============================================================================================
# 정리(라이브 서버용): 만든 계정을 지운다
# =============================================================================================
def cleanup(R):
    def f():
        n = 0
        t = R.ctx.get("app_access")
        if t:
            r = api(R, "DELETE", "/v1/me", t)
            if r.status == 204:
                n += 1
        for u, pw in R.ctx.get("throwaway_users", []):
            l = R.http.post("/v1/auth/password/login", json_body={"username": u, "password": pw}, retry429=False)
            if l.status == 200:
                if api(R, "DELETE", "/v1/me", l.json()["accessToken"]).status == 204:
                    n += 1
        return f"계정 {n}개 삭제"
    R.run("cleanup.delete_throwaway_accounts", f)


# =============================================================================================
def main():
    ap = argparse.ArgumentParser(description="Fitlog E2E (블랙박스)")
    ap.add_argument("--base-url", default=os.environ.get("E2E_BASE_URL", "http://localhost:8080"))
    ap.add_argument("--public-base-url", default=os.environ.get("E2E_PUBLIC_BASE_URL"),
                    help="서버가 메타데이터에 써야 하는 공개 주소(PUBLIC_BASE_URL). 기본은 --base-url")
    ap.add_argument("--phase", choices=["all", "before-restart", "after-restart"], default="all")
    ap.add_argument("--state", default=os.path.join(ROOT, "e2e", ".state.json"))
    ap.add_argument("--signup-code", default=os.environ.get("E2E_SIGNUP_CODE"), help="PASSWORD_SIGNUP_CODE 값(없으면 가입이 필요한 점검 불가)")
    ap.add_argument("--consent-version", default=None, help="앱의 consentVersion. 기본은 app/lib/core/config.dart 에서 읽음")
    ap.add_argument("--wait", type=int, default=90, help="서버가 준비될 때까지 기다리는 최대 초(무료 호스팅 콜드 스타트)")
    ap.add_argument("--cleanup", action="store_true", help="끝에서 이 실행이 만든 계정을 삭제(라이브 서버용)")
    ap.add_argument("--reuse-grace-wait", type=int, default=62, help="리프레시 재사용 유예(서버 60초) 뒤 점검 전에 기다리는 초. 0 이면 바로 점검")
    ap.add_argument("--verbose", "-v", action="store_true")
    args = ap.parse_args()

    R = Runner(args)
    print(f"Fitlog E2E  base={args.base_url}  public={R.public}  phase={args.phase}")
    print("=" * 78)

    def section(title, fn):
        print(title)
        try:
            fn(R)
        except Fail as e:
            R.results.append((title, False, str(e), ""))
            print(f"  FAIL  {title}\n        -> {e}")

    if args.phase in ("all", "before-restart"):
        if not args.signup_code:
            print("오류: --signup-code(또는 E2E_SIGNUP_CODE)가 필요합니다.", file=sys.stderr)
            return 2
        print("[헬스]")
        c_health(R)
        print("[OAuth·MCP 메타데이터 / 프록시]")
        c_metadata(R)
        print("[비밀번호 인증 · 동의]")
        c_auth(R)
        print("[앱 REST 흐름]")
        c_app_flow(R)
        section("[OAuth 등록·인가·토큰]", c_oauth)
        section("[MCP 프로토콜]", mcp_protocol)
        section("[MCP 도구]", mcp_tools)
        print("[리프레시 재사용 감지(유예 대기 포함)]")
        c_reuse_after_grace(R)
        if args.phase == "before-restart":
            finish_before(R)
        elif args.cleanup:
            print("[정리]")
            cleanup(R)
    else:
        print("[헬스]")
        c_health(R)
        print("[재시작 뒤 확인]")
        after_restart(R)

    print("=" * 78)
    fails = [r for r in R.results if not r[1]]
    known = [r for r in fails if r[0] in KNOWN_DEFECTS]
    print(f"결과 RESULT: {len(R.results) - len(fails)} PASS / {len(fails)} FAIL / 총 {len(R.results)}")
    if fails:
        print("\n실패한 점검 FAILED:")
        for n, _, m, _ in fails:
            print(f"  - {n}{'  [알려진 서버 결함: ' + KNOWN_DEFECTS[n] + ']' if n in KNOWN_DEFECTS else ''}\n      {m}")
        if known:
            print(f"\n(이 중 {len(known)}개는 알려진 서버 결함 때문입니다)")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
