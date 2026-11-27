package com.fitlog.oauth

import com.fitlog.account.ensureSettings
import com.fitlog.auth.GoogleIdTokenVerifierImpl
import com.fitlog.auth.PasswordAuthResult
import com.fitlog.auth.authenticatePassword
import com.fitlog.core.AiConnections
import com.fitlog.core.AppConfig
import com.fitlog.core.AppUsers
import com.fitlog.core.GoogleIdTokenVerifier
import com.fitlog.core.Ids
import com.fitlog.core.OAuthAuthCodes
import com.fitlog.core.OAuthClients
import com.fitlog.core.OAuthTokens
import com.fitlog.core.Times
import com.fitlog.core.dbQuery
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.withCharset
import io.ktor.server.application.ApplicationCall
import io.ktor.server.request.receiveParameters
import io.ktor.server.request.receiveText
import io.ktor.server.response.header
import io.ktor.server.response.respondRedirect
import io.ktor.server.response.respondText
import io.ktor.server.routing.Route
import io.ktor.server.routing.get
import io.ktor.server.routing.post
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import org.jetbrains.exposed.sql.SqlExpressionBuilder.eq
import org.jetbrains.exposed.sql.and
import org.jetbrains.exposed.sql.insert
import org.jetbrains.exposed.sql.insertIgnore
import org.jetbrains.exposed.sql.selectAll
import org.jetbrains.exposed.sql.update
import java.net.URI
import java.util.UUID

private class ClientRow(val id: UUID, val clientId: String, val name: String, val redirectUris: List<String>)

private suspend fun findClient(clientId: String?): ClientRow? {
    if (clientId.isNullOrEmpty()) return null
    return dbQuery {
        OAuthClients.selectAll().where { OAuthClients.clientId eq clientId }.singleOrNull()?.let {
            ClientRow(it[OAuthClients.id], it[OAuthClients.clientId], it[OAuthClients.clientName], it[OAuthClients.redirectUris])
        }
    }
}

private suspend fun ApplicationCall.noStore() {
    response.header(HttpHeaders.CacheControl, "no-store")
    response.header("Pragma", "no-cache")
}

private suspend fun ApplicationCall.html(status: HttpStatusCode, body: String) {
    noStore()
    response.header("X-Frame-Options", "DENY")
    response.header("Content-Security-Policy", "frame-ancestors 'none'")
    respondText(body, ContentType.Text.Html.withCharset(Charsets.UTF_8), status)
}

private suspend fun ApplicationCall.json(status: HttpStatusCode, body: JsonElement) {
    noStore()
    respondText(body.toString(), ContentType.Application.Json, status)
}

private suspend fun ApplicationCall.oauthError(status: HttpStatusCode, error: String, description: String) =
    json(status, buildJsonObject { put("error", error); put("error_description", description) })

private fun parseScopes(raw: String?): List<String>? {
    val req = raw?.split(' ', '+')?.filter { it.isNotBlank() }.orEmpty()
    if (req.isEmpty()) return SUPPORTED_SCOPES
    val known = req.filter { it in SUPPORTED_SCOPES }
    // 모르는 범위(openid 등)만 요청한 클라이언트도 막지 않고 기본 범위로 진행한다. 실제 부여는 동의 화면에서 정한다
    if (known.isEmpty()) return SUPPORTED_SCOPES
    return (listOf(SCOPE_READ) + known).distinct() // 쓰기는 읽기를 포함한다
}

private fun validRedirectUri(s: String): Boolean {
    val u = runCatching { URI(s) }.getOrNull() ?: return false
    if (u.fragment != null || u.host.isNullOrEmpty() || u.userInfo != null) return false
    return when (u.scheme) {
        "https" -> true
        "http" -> u.host == "localhost" || u.host == "127.0.0.1"
        else -> false
    }
}

private sealed interface TokenResult {
    class Ok(val pair: TokenPair, val scopes: List<String>) : TokenResult
    class Err(val error: String, val description: String) : TokenResult
}

/** A2 소유 (v0.3). 등록 위치: 루트(/.well-known/..., /oauth/...), 인증 없음 */
fun Route.oauthRoutes(config: AppConfig) {
    val base = config.publicBaseUrl
    val secret = config.jwt.secret
    val googleCallback = "$base/oauth/google/callback"
    val verifier: GoogleIdTokenVerifier by lazy {
        config.googleVerifier ?: GoogleIdTokenVerifierImpl(listOfNotNull(config.googleWebClientId) + config.googleClientIds)
    }
    val exchanger by lazy {
        config.googleCodeExchanger
            ?: GoogleCodeExchangerImpl(config.googleWebClientId.orEmpty(), config.googleWebClientSecret.orEmpty())
    }

    // ---------------------------------------------------------------- 메타데이터
    val protectedResource = buildJsonObject {
        put("resource", config.mcpUrl())
        putJsonArray("authorization_servers") { add(JsonPrimitive(base)) }
        putJsonArray("scopes_supported") { SUPPORTED_SCOPES.forEach { add(JsonPrimitive(it)) } }
        putJsonArray("bearer_methods_supported") { add(JsonPrimitive("header")) }
        put("resource_name", "Fitlog")
    }
    val authServer = buildJsonObject {
        put("issuer", base)
        put("authorization_endpoint", "$base/oauth/authorize")
        put("token_endpoint", "$base/oauth/token")
        put("registration_endpoint", "$base/oauth/register")
        putJsonArray("response_types_supported") { add(JsonPrimitive("code")) }
        putJsonArray("grant_types_supported") { add(JsonPrimitive("authorization_code")); add(JsonPrimitive("refresh_token")) }
        putJsonArray("code_challenge_methods_supported") { add(JsonPrimitive("S256")) }
        putJsonArray("token_endpoint_auth_methods_supported") {
            listOf("none", "client_secret_post", "client_secret_basic").forEach { add(JsonPrimitive(it)) }
        }
        putJsonArray("scopes_supported") { SUPPORTED_SCOPES.forEach { add(JsonPrimitive(it)) } }
    }
    for (p in listOf("/.well-known/oauth-protected-resource", "/.well-known/oauth-protected-resource/{path...}")) {
        get(p) { call.json(HttpStatusCode.OK, protectedResource) }
    }
    for (p in listOf("/.well-known/oauth-authorization-server", "/.well-known/oauth-authorization-server/{path...}")) {
        get(p) { call.json(HttpStatusCode.OK, authServer) }
    }

    // ---------------------------------------------------------------- 동적 클라이언트 등록 (RFC 7591)
    post("/oauth/register") {
        val body = try {
            Json.parseToJsonElement(call.receiveText()) as? JsonObject
        } catch (e: Exception) {
            null
        }
        if (body == null) return@post call.oauthError(HttpStatusCode.BadRequest, "invalid_client_metadata", "body must be a JSON object")
        // client_name 은 선택(RFC 7591). 없으면 기본 이름, 길면 자른다
        val name = (body["client_name"] as? JsonPrimitive)?.takeIf { it.isString }?.content?.trim()
            ?.takeIf { it.isNotEmpty() }?.take(100) ?: "AI 앱"
        val uris = (body["redirect_uris"] as? JsonArray)?.map { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content }
        if (uris.isNullOrEmpty() || uris.size > 10 || uris.any { it == null || !validRedirectUri(it) }) {
            return@post call.oauthError(
                HttpStatusCode.BadRequest, "invalid_redirect_uri",
                "redirect_uris must be 1..10 URIs: https, or http on localhost/127.0.0.1, without fragment",
            )
        }
        // 일부 클라이언트(ChatGPT 등)는 client_secret_post/basic 으로 등록한다. 거절하면 연결이 아예 안 되므로
        // 비밀값을 발급해 돌려주되, 보호는 PKCE·등록된 redirect_uri 로 하고 토큰 엔드포인트에서 비밀값은 검사하지 않는다
        val requestedMethod = (body["token_endpoint_auth_method"] as? JsonPrimitive)?.contentOrNull
        val method = if (requestedMethod == "client_secret_post" || requestedMethod == "client_secret_basic") requestedMethod else "none"
        val clientId = newSecret("fitlog_").take(40)
        val now = Times.now()
        dbQuery {
            OAuthClients.insert {
                it[id] = Ids.newId()
                it[OAuthClients.clientId] = clientId
                it[clientName] = name
                it[redirectUris] = uris.filterNotNull().distinct()
                it[createdAt] = now
            }
        }
        call.json(
            HttpStatusCode.Created,
            buildJsonObject {
                put("client_id", clientId)
                put("client_id_issued_at", now.epochSecond)
                put("client_name", name)
                putJsonArray("redirect_uris") { uris.filterNotNull().distinct().forEach { add(JsonPrimitive(it)) } }
                put("token_endpoint_auth_method", method)
                if (method != "none") {
                    put("client_secret", newSecret("fitlogs_"))
                    put("client_secret_expires_at", 0)
                }
                putJsonArray("grant_types") { add(JsonPrimitive("authorization_code")); add(JsonPrimitive("refresh_token")) }
                putJsonArray("response_types") { add(JsonPrimitive("code")) }
            },
        )
    }

    // ---------------------------------------------------------------- 인가 엔드포인트
    get("/oauth/authorize") {
        val q = call.request.queryParameters
        val client = findClient(q["client_id"])
        val redirectUri = q["redirect_uri"]
        if (client == null) return@get call.html(HttpStatusCode.BadRequest, OAuthPages.error("잘못된 요청", "등록되지 않은 클라이언트입니다."))
        if (redirectUri == null || redirectUri !in client.redirectUris) {
            return@get call.html(HttpStatusCode.BadRequest, OAuthPages.error("잘못된 요청", "redirect_uri 가 등록된 값과 다릅니다."))
        }
        val state = q["state"]
        suspend fun fail(error: String, desc: String) =
            call.respondRedirect(appendQuery(redirectUri, mapOf("error" to error, "error_description" to desc, "state" to state)))

        if (q["response_type"] != "code") return@get fail("unsupported_response_type", "response_type must be code")
        val challenge = q["code_challenge"]
        if (challenge.isNullOrEmpty() || q["code_challenge_method"] != "S256") {
            return@get fail("invalid_request", "PKCE with code_challenge_method=S256 is required")
        }
        val resource = q["resource"]
        if (resource != null && resource.trimEnd('/') != config.mcpUrl()) return@get fail("invalid_target", "resource must be ${config.mcpUrl()}")
        val scopes = parseScopes(q["scope"]) ?: return@get fail("invalid_scope", "supported scopes: ${SUPPORTED_SCOPES.joinToString(" ")}")
        val webClientId = config.googleWebClientId?.takeIf { it.isNotEmpty() }
        if (webClientId == null && !config.passwordLogin.enabled) {
            return@get call.html(HttpStatusCode.ServiceUnavailable, OAuthPages.error("로그인을 사용할 수 없음", "서버에 Google 웹 로그인이 설정되지 않았습니다."))
        }
        val signed = Signer.sign(
            secret, "authz",
            mapOf(
                "cid" to client.clientId, "ru" to redirectUri, "cc" to challenge, "st" to (state ?: ""),
                "sc" to scopes.joinToString(" "), "res" to (resource ?: ""),
            ),
            AUTH_CODE_TTL_SEC,
        )
        val googleUrl = webClientId?.let {
            appendQuery(
                "https://accounts.google.com/o/oauth2/v2/auth",
                mapOf(
                    "client_id" to it,
                    "redirect_uri" to googleCallback,
                    "response_type" to "code",
                    "scope" to "openid email profile",
                    "state" to signed,
                    "prompt" to "select_account",
                ),
            )
        }
        call.noStore()
        if (config.passwordLogin.enabled) {
            return@get call.html(HttpStatusCode.OK, OAuthPages.login(client.name, signed, "$base/oauth/password", googleUrl))
        }
        call.respondRedirect(googleUrl!!)
    }

    // ---------------------------------------------------------------- 아이디·비밀번호 로그인 (테스트 서버)
    post("/oauth/password") {
        call.noStore()
        val params = call.receiveParameters()
        val token = params["authz"]
        val st = Signer.verify(secret, "authz", token)
            ?: return@post call.html(HttpStatusCode.BadRequest, OAuthPages.error("잘못된 요청", "로그인 요청이 만료되었거나 올바르지 않습니다. 처음부터 다시 시도해 주세요."))
        if (!config.passwordLogin.enabled) {
            return@post call.html(HttpStatusCode.NotFound, OAuthPages.error("로그인을 사용할 수 없음", "이 서버는 아이디·비밀번호 로그인을 사용하지 않습니다."))
        }
        val client = findClient(st["cid"])
            ?: return@post call.html(HttpStatusCode.BadRequest, OAuthPages.error("잘못된 요청", "등록되지 않은 클라이언트입니다."))
        val username = params["username"].orEmpty()
        val password = params["password"].orEmpty()
        val webClientId = config.googleWebClientId?.takeIf { it.isNotEmpty() }
        val googleUrl = webClientId?.let {
            appendQuery(
                "https://accounts.google.com/o/oauth2/v2/auth",
                mapOf(
                    "client_id" to it, "redirect_uri" to googleCallback, "response_type" to "code",
                    "scope" to "openid email profile", "state" to token, "prompt" to "select_account",
                ),
            )
        }
        suspend fun again(status: HttpStatusCode, msg: String) =
            call.html(status, OAuthPages.login(client.name, token!!, "$base/oauth/password", googleUrl, msg))

        if (username.length > 64 || password.length > 128) return@post again(HttpStatusCode.Unauthorized, "아이디 또는 비밀번호가 올바르지 않습니다.")
        when (val r = authenticatePassword(username, password)) {
            PasswordAuthResult.Invalid -> again(HttpStatusCode.Unauthorized, "아이디 또는 비밀번호가 올바르지 않습니다.")
            is PasswordAuthResult.Locked -> {
                call.response.header(HttpHeaders.RetryAfter, r.retryAfterSec.toString())
                again(HttpStatusCode.TooManyRequests, "로그인 시도가 너무 많아 잠겼습니다. ${(r.retryAfterSec + 59) / 60}분 뒤에 다시 시도해 주세요.")
            }
            is PasswordAuthResult.Ok -> {
                val scopes = st.getValue("sc").split(' ').filter { it.isNotEmpty() }
                val form = Signer.sign(secret, "consent", st + mapOf("uid" to r.userId.toString()), AUTH_CODE_TTL_SEC)
                call.html(
                    HttpStatusCode.OK,
                    OAuthPages.consent(client.name, username.trim().lowercase(), SCOPE_WRITE in scopes, form, "$base/oauth/consent"),
                )
            }
        }
    }

    // ---------------------------------------------------------------- Google 웹 로그인 콜백
    get("/oauth/google/callback") {
        val q = call.request.queryParameters
        val st = Signer.verify(secret, "authz", q["state"])
            ?: return@get call.html(HttpStatusCode.BadRequest, OAuthPages.error("잘못된 요청", "로그인 요청이 만료되었거나 올바르지 않습니다. 처음부터 다시 시도해 주세요."))
        val redirectUri = st.getValue("ru")
        val clientState = st["st"]?.ifEmpty { null }
        val code = q["code"]
        if (q["error"] != null || code.isNullOrEmpty()) {
            return@get call.respondRedirect(appendQuery(redirectUri, mapOf("error" to "access_denied", "state" to clientState)))
        }
        val client = findClient(st["cid"])
            ?: return@get call.html(HttpStatusCode.BadRequest, OAuthPages.error("잘못된 요청", "등록되지 않은 클라이언트입니다."))
        val identity = withContext(Dispatchers.IO) {
            val idToken = exchanger.exchange(code, googleCallback) ?: return@withContext null
            verifier.verify(idToken)
        } ?: return@get call.html(HttpStatusCode.BadRequest, OAuthPages.error("로그인 실패", "Google 로그인을 확인하지 못했습니다. 다시 시도해 주세요."))

        val userId = dbQuery {
            val now = Times.now()
            var user = AppUsers.selectAll().where { AppUsers.googleSub eq identity.sub }.singleOrNull()
            if (user == null) {
                AppUsers.insertIgnore {
                    it[id] = Ids.newId()
                    it[googleSub] = identity.sub
                    it[email] = identity.email
                    it[displayName] = identity.name
                    it[role] = "MEMBER"
                    it[createdAt] = now
                    it[updatedAt] = now
                }
                user = AppUsers.selectAll().where { AppUsers.googleSub eq identity.sub }.single()
            } else {
                AppUsers.update({ AppUsers.id eq user!![AppUsers.id] }) {
                    it[email] = identity.email
                    it[displayName] = identity.name
                    it[updatedAt] = now
                }
            }
            val id = user!![AppUsers.id]
            ensureSettings(id)
            id
        }
        val scopes = st.getValue("sc").split(' ').filter { it.isNotEmpty() }
        val form = Signer.sign(
            secret, "consent",
            st + mapOf("uid" to userId.toString()),
            AUTH_CODE_TTL_SEC,
        )
        call.html(
            HttpStatusCode.OK,
            OAuthPages.consent(client.name, identity.email, SCOPE_WRITE in scopes, form, "$base/oauth/consent"),
        )
    }

    // ---------------------------------------------------------------- 동의
    post("/oauth/consent") {
        val params = call.receiveParameters()
        val f = Signer.verify(secret, "consent", params["form"])
            ?: return@post call.html(HttpStatusCode.BadRequest, OAuthPages.error("잘못된 요청", "동의 요청이 만료되었거나 올바르지 않습니다. 처음부터 다시 시도해 주세요."))
        val redirectUri = f.getValue("ru")
        val clientState = f["st"]?.ifEmpty { null }
        val client = findClient(f["cid"])
            ?: return@post call.html(HttpStatusCode.BadRequest, OAuthPages.error("잘못된 요청", "등록되지 않은 클라이언트입니다."))
        if (redirectUri !in client.redirectUris) {
            return@post call.html(HttpStatusCode.BadRequest, OAuthPages.error("잘못된 요청", "redirect_uri 가 등록된 값과 다릅니다."))
        }
        if (params["decision"] != "allow") {
            return@post call.respondRedirect(appendQuery(redirectUri, mapOf("error" to "access_denied", "state" to clientState)))
        }
        val requested = f.getValue("sc").split(' ').filter { it.isNotEmpty() }
        val granted = if (SCOPE_WRITE in requested && params["write"] != null) listOf(SCOPE_READ, SCOPE_WRITE) else listOf(SCOPE_READ)
        val userId = UUID.fromString(f.getValue("uid"))
        val rawCode = newSecret("flc_")
        dbQuery {
            val now = Times.now()
            val existing = AiConnections.selectAll()
                .where { (AiConnections.userId eq userId) and (AiConnections.clientId eq client.id) }
                .forUpdate().singleOrNull()
            val connId: UUID
            if (existing == null) {
                connId = Ids.newId()
                AiConnections.insert {
                    it[id] = connId
                    it[AiConnections.userId] = userId
                    it[clientId] = client.id
                    it[scopes] = granted
                    it[createdAt] = now
                }
            } else {
                connId = existing[AiConnections.id]
                // 끊겼던 연결을 다시 연결하면 옛 토큰이 되살아나지 않도록 모두 폐기한다
                if (existing[AiConnections.revokedAt] != null) revokeConnectionTokens(connId)
                AiConnections.update({ AiConnections.id eq connId }) {
                    it[scopes] = granted
                    it[revokedAt] = null
                }
            }
            OAuthAuthCodes.insert {
                it[codeHash] = sha256Hex(rawCode)
                it[connectionId] = connId
                it[OAuthAuthCodes.redirectUri] = redirectUri
                it[codeChallenge] = f.getValue("cc")
                it[scopes] = granted
                it[expiresAt] = now.plusSeconds(AUTH_CODE_TTL_SEC)
            }
        }
        call.noStore()
        call.respondRedirect(appendQuery(redirectUri, mapOf("code" to rawCode, "state" to clientState)))
    }

    // ---------------------------------------------------------------- 토큰 엔드포인트
    post("/oauth/token") {
        val p = try {
            call.receiveParameters()
        } catch (e: Exception) {
            return@post call.oauthError(HttpStatusCode.BadRequest, "invalid_request", "application/x-www-form-urlencoded body required")
        }
        val resource = p["resource"]
        if (resource != null && resource.trimEnd('/') != config.mcpUrl()) {
            return@post call.oauthError(HttpStatusCode.BadRequest, "invalid_target", "resource must be ${config.mcpUrl()}")
        }
        val clientIdParam = p["client_id"]
        val result: TokenResult = when (p["grant_type"]) {
            "authorization_code" -> {
                val code = p["code"]
                val verifierParam = p["code_verifier"]
                val redirectUri = p["redirect_uri"]
                if (code.isNullOrEmpty() || verifierParam.isNullOrEmpty() || redirectUri.isNullOrEmpty()) {
                    TokenResult.Err("invalid_request", "code, code_verifier and redirect_uri are required")
                } else dbQuery {
                    val now = Times.now()
                    val row = OAuthAuthCodes.selectAll().where { OAuthAuthCodes.codeHash eq sha256Hex(code) }
                        .forUpdate().singleOrNull() ?: return@dbQuery TokenResult.Err("invalid_grant", "unknown authorization code")
                    val connId = row[OAuthAuthCodes.connectionId]
                    if (row[OAuthAuthCodes.usedAt] != null) {
                        // 사용된 코드의 재사용 = 탈취 의심. 이 연결의 토큰을 모두 폐기한다
                        revokeConnectionTokens(connId)
                        return@dbQuery TokenResult.Err("invalid_grant", "authorization code already used")
                    }
                    if (!row[OAuthAuthCodes.expiresAt].isAfter(now)) return@dbQuery TokenResult.Err("invalid_grant", "authorization code expired")
                    if (row[OAuthAuthCodes.redirectUri] != redirectUri) return@dbQuery TokenResult.Err("invalid_grant", "redirect_uri mismatch")
                    if (!constantTimeEquals(pkceChallenge(verifierParam), row[OAuthAuthCodes.codeChallenge])) {
                        return@dbQuery TokenResult.Err("invalid_grant", "PKCE verification failed")
                    }
                    val conn = AiConnections.join(OAuthClients, org.jetbrains.exposed.sql.JoinType.INNER, AiConnections.clientId, OAuthClients.id)
                        .selectAll().where { AiConnections.id eq connId }.single()
                    if (conn[AiConnections.revokedAt] != null) return@dbQuery TokenResult.Err("invalid_grant", "connection revoked")
                    if (clientIdParam != null && clientIdParam != conn[OAuthClients.clientId]) {
                        return@dbQuery TokenResult.Err("invalid_grant", "client_id mismatch")
                    }
                    OAuthAuthCodes.update({ OAuthAuthCodes.codeHash eq row[OAuthAuthCodes.codeHash] }) { it[usedAt] = now }
                    TokenResult.Ok(issueTokenPair(connId, Ids.newId()), row[OAuthAuthCodes.scopes])
                }
            }
            "refresh_token" -> {
                val refresh = p["refresh_token"]
                if (refresh.isNullOrEmpty()) TokenResult.Err("invalid_request", "refresh_token is required")
                else dbQuery {
                    val now = Times.now()
                    val row = OAuthTokens.selectAll()
                        .where { (OAuthTokens.tokenHash eq sha256Hex(refresh)) and (OAuthTokens.kind eq "REFRESH") }
                        .forUpdate().singleOrNull() ?: return@dbQuery TokenResult.Err("invalid_grant", "unknown refresh token")
                    val connId = row[OAuthTokens.connectionId]
                    if (row[OAuthTokens.revokedAt] != null) {
                        // 이미 회전된 토큰의 재사용 = 탈취 의심. 계열(그 연결의 토큰) 전부 폐기
                        revokeConnectionTokens(connId)
                        return@dbQuery TokenResult.Err("invalid_grant", "refresh token reuse detected; connection tokens revoked")
                    }
                    if (!row[OAuthTokens.expiresAt].isAfter(now)) return@dbQuery TokenResult.Err("invalid_grant", "refresh token expired")
                    val conn = AiConnections.join(OAuthClients, org.jetbrains.exposed.sql.JoinType.INNER, AiConnections.clientId, OAuthClients.id)
                        .selectAll().where { AiConnections.id eq connId }.single()
                    if (conn[AiConnections.revokedAt] != null) return@dbQuery TokenResult.Err("invalid_grant", "connection revoked")
                    if (clientIdParam != null && clientIdParam != conn[OAuthClients.clientId]) {
                        return@dbQuery TokenResult.Err("invalid_grant", "client_id mismatch")
                    }
                    OAuthTokens.update({ OAuthTokens.id eq row[OAuthTokens.id] }) { it[revokedAt] = now }
                    TokenResult.Ok(issueTokenPair(connId, row[OAuthTokens.familyId]), conn[AiConnections.scopes])
                }
            }
            else -> TokenResult.Err("unsupported_grant_type", "grant_type must be authorization_code or refresh_token")
        }
        when (result) {
            is TokenResult.Err -> call.oauthError(HttpStatusCode.BadRequest, result.error, result.description)
            is TokenResult.Ok -> call.json(
                HttpStatusCode.OK,
                buildJsonObject {
                    put("access_token", result.pair.access)
                    put("token_type", "Bearer")
                    put("expires_in", ACCESS_TTL_SEC)
                    put("refresh_token", result.pair.refresh)
                    put("scope", result.scopes.joinToString(" "))
                },
            )
        }
    }
}
