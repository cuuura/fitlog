package com.fitlog.oauth

import com.fitlog.core.AiConnections
import com.fitlog.core.AppConfig
import com.fitlog.core.AppUsers
import com.fitlog.core.GoogleCodeExchanger
import com.fitlog.core.OAuthClients
import com.fitlog.core.Ids
import com.fitlog.core.Times
import com.fitlog.importing.ImportBatch
import com.fitlog.importing.ImportContext
import com.fitlog.importing.ImportOutcome
import com.fitlog.importing.ImportPreview
import com.fitlog.importing.ImportRequest
import com.fitlog.importing.Importer
import com.fitlog.module
import com.fitlog.support.TestEnv
import io.ktor.client.HttpClient
import io.ktor.client.request.forms.FormDataContent
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.Parameters
import io.ktor.http.Url
import io.ktor.http.contentType
import io.ktor.server.testing.ApplicationTestBuilder
import io.ktor.server.testing.testApplication
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.jetbrains.exposed.sql.JoinType
import org.jetbrains.exposed.sql.SqlExpressionBuilder.eq
import org.jetbrains.exposed.sql.and
import org.jetbrains.exposed.sql.selectAll
import org.jetbrains.exposed.sql.transactions.transaction
import java.security.MessageDigest
import java.util.Base64
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList

const val TEST_BASE = "https://fitlog.test"
const val TEST_REDIRECT = "http://localhost:7777/callback"

/** 가짜 Google: 인가 코드가 곧 "test:<sub>:<email>" ID 토큰이다 (TestEnv 가짜 검증기가 받아들이는 형식) */
val fakeExchanger = GoogleCodeExchanger { code, _ -> if (code.startsWith("test:")) code else null }

fun a2Config(importer: Importer? = null): AppConfig = TestEnv.config.copy(
    publicBaseUrl = TEST_BASE,
    googleWebClientId = "web-client-id",
    googleWebClientSecret = "web-secret",
    googleCodeExchanger = fakeExchanger,
    importerOverride = importer,
)

fun a2Test(config: AppConfig = a2Config(), block: suspend ApplicationTestBuilder.() -> Unit) = testApplication {
    application { module(config) }
    block()
}

/** 리다이렉트를 따라가지 않는 클라이언트 */
fun ApplicationTestBuilder.plainClient(): HttpClient = createClient { followRedirects = false }

/** 호출을 기록하는 가짜 가져오기 구현 */
class FakeImporter(
    var outcome: (ImportContext, ImportRequest) -> ImportOutcome = { ctx, req ->
        ImportOutcome.Saved(
            ImportBatch(Ids.newId(), Times.now(), "MCP", ctx.clientName, null, mapOf("sessions" to 1)),
            created = true,
        )
    },
) : Importer {
    val calls = CopyOnWriteArrayList<Pair<ImportContext, ImportRequest>>()
    override suspend fun preview(ctx: ImportContext, req: ImportRequest): ImportPreview = error("not used by MCP tools")
    override suspend fun import(ctx: ImportContext, req: ImportRequest): ImportOutcome {
        calls += ctx to req
        return outcome(ctx, req)
    }
}

fun pkceVerifier(): String = Base64.getUrlEncoder().withoutPadding().encodeToString(ByteArray(32).also { java.security.SecureRandom().nextBytes(it) })
fun challengeOf(v: String): String = Base64.getUrlEncoder().withoutPadding().encodeToString(MessageDigest.getInstance("SHA-256").digest(v.toByteArray()))

fun form(vararg p: Pair<String, String>) = FormDataContent(Parameters.build { p.forEach { (k, v) -> append(k, v) } })

suspend fun HttpResponse.json(): JsonObject = Json.parseToJsonElement(bodyAsText()).jsonObject

/** 동적 등록. client_id 를 돌려준다 */
suspend fun HttpClient.registerClient(name: String = "Claude Test", redirect: String = TEST_REDIRECT): String {
    val res = post("/oauth/register") {
        contentType(ContentType.Application.Json)
        setBody("""{"client_name":"$name","redirect_uris":["$redirect"],"token_endpoint_auth_method":"none"}""")
    }
    check(res.status.value == 201) { "register failed: ${res.status} ${res.bodyAsText()}" }
    return res.json()["client_id"]!!.jsonPrimitive.content
}

fun authorizeUrl(
    clientId: String, challenge: String, state: String = "xyz", redirect: String = TEST_REDIRECT, scope: String? = null,
    resource: String? = null, method: String? = "S256",
): String = buildString {
    append("/oauth/authorize?response_type=code&client_id=").append(urlEnc(clientId))
    append("&redirect_uri=").append(urlEnc(redirect))
    if (challenge.isNotEmpty()) append("&code_challenge=").append(challenge)
    if (method != null) append("&code_challenge_method=").append(method)
    append("&state=").append(state)
    if (scope != null) append("&scope=").append(urlEnc(scope))
    if (resource != null) append("&resource=").append(urlEnc(resource))
}

fun HttpResponse.location(): Url = Url(headers[HttpHeaders.Location] ?: error("no Location header (status $status)"))

class Connected(
    val clientId: String,
    val sub: String,
    val userId: UUID,
    val access: String,
    val refresh: String,
    val scope: String,
    val connectionId: UUID,
)

/** authorize → Google 콜백(가짜) → 동의 페이지. 동의 폼 값을 돌려준다 */
suspend fun HttpClient.loginUntilConsent(
    clientId: String, sub: String, challenge: String, state: String = "xyz", scope: String? = null,
): String {
    val auth = get(authorizeUrl(clientId, challenge, state, scope = scope))
    check(auth.status.value == 302) { "authorize: ${auth.status} ${auth.bodyAsText()}" }
    val loc = auth.location()
    check(loc.host == "accounts.google.com") { "unexpected redirect $loc" }
    val signedState = loc.parameters["state"]!!
    val cb = get("/oauth/google/callback?code=${urlEnc("test:$sub:$sub@test.local")}&state=${urlEnc(signedState)}")
    check(cb.status.value == 200) { "callback: ${cb.status} ${cb.bodyAsText()}" }
    return Regex("name=\"form\" value=\"([^\"]+)\"").find(cb.bodyAsText())!!.groupValues[1]
}

/** 전체 연결: 등록 → authorize → 로그인 → 동의 → 토큰. write=false 면 쓰기 체크박스를 끈다 */
suspend fun HttpClient.connect(
    clientName: String = "Claude Test",
    write: Boolean = true,
    sub: String = "g-" + UUID.randomUUID().toString().take(12),
    clientId: String? = null,
): Connected {
    val cid = clientId ?: registerClient(clientName)
    val verifier = pkceVerifier()
    val formToken = loginUntilConsent(cid, sub, challengeOf(verifier))
    val consent = post("/oauth/consent") {
        setBody(
            if (write) form("form" to formToken, "decision" to "allow", "write" to "1")
            else form("form" to formToken, "decision" to "allow"),
        )
    }
    check(consent.status.value == 302) { "consent: ${consent.status} ${consent.bodyAsText()}" }
    val code = consent.location().parameters["code"]!!
    val tok = post("/oauth/token") {
        setBody(form("grant_type" to "authorization_code", "code" to code, "redirect_uri" to TEST_REDIRECT, "code_verifier" to verifier, "client_id" to cid))
    }
    check(tok.status.value == 200) { "token: ${tok.status} ${tok.bodyAsText()}" }
    val j = tok.json()
    val uid = transaction { AppUsers.selectAll().where { AppUsers.googleSub eq sub }.single()[AppUsers.id] }
    val connId = transaction {
        AiConnections.join(OAuthClients, JoinType.INNER, AiConnections.clientId, OAuthClients.id)
            .selectAll().where { (AiConnections.userId eq uid) and (OAuthClients.clientId eq cid) }
            .single()[AiConnections.id]
    }
    return Connected(
        cid, sub, uid, j["access_token"]!!.jsonPrimitive.content, j["refresh_token"]!!.jsonPrimitive.content,
        j["scope"]!!.jsonPrimitive.content, connId,
    )
}

// ---------------------------------------------------------------- MCP 호출 도구

suspend fun HttpClient.mcpPost(token: String?, session: String?, body: String): HttpResponse = post("/mcp") {
    if (token != null) header(HttpHeaders.Authorization, "Bearer $token")
    if (session != null) header("Mcp-Session-Id", session)
    header(HttpHeaders.Accept, "application/json, text/event-stream")
    contentType(ContentType.Application.Json)
    setBody(body)
}

/** initialize → Mcp-Session-Id */
suspend fun HttpClient.mcpInit(token: String): String {
    val res = mcpPost(
        token, null,
        """{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}""",
    )
    check(res.status.value == 200) { "initialize: ${res.status} ${res.bodyAsText()}" }
    val sid = res.headers["Mcp-Session-Id"]!!
    val note = mcpPost(token, sid, """{"jsonrpc":"2.0","method":"notifications/initialized"}""")
    check(note.status.value == 202)
    return sid
}

/** tools/call → 응답 JSON-RPC 객체 전체 */
suspend fun HttpClient.mcpCall(token: String, session: String, tool: String, args: String = "{}"): JsonObject =
    mcpPost(token, session, """{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"$tool","arguments":$args}}""").json()

/** result 객체 (JSON-RPC 에러면 실패) */
fun JsonObject.result(): JsonObject = this["result"]?.jsonObject ?: error("no result: $this")
