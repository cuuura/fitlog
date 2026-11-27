package com.fitlog.mcp

import com.fitlog.core.AiToolCalls
import com.fitlog.core.ApiException
import com.fitlog.core.AppConfig
import com.fitlog.core.ErrorCode
import com.fitlog.core.Times
import com.fitlog.core.dbQuery
import com.fitlog.oauth.McpPrincipal
import com.fitlog.oauth.OAuthTokenService
import com.fitlog.oauth.SCOPE_READ
import com.fitlog.oauth.SCOPE_WRITE
import com.fitlog.oauth.Signer
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.server.application.ApplicationCall
import io.ktor.server.request.header
import io.ktor.server.request.receiveText
import io.ktor.server.response.header
import io.ktor.server.response.respondText
import io.ktor.server.routing.Route
import io.ktor.server.routing.delete
import io.ktor.server.routing.get
import io.ktor.server.routing.post
import io.ktor.server.routing.route
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.put
import org.jetbrains.exposed.sql.insert
import org.slf4j.LoggerFactory
import java.util.ArrayDeque
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

private val log = LoggerFactory.getLogger("com.fitlog.mcp")

internal const val LATEST_PROTOCOL = "2025-06-18"
internal val SUPPORTED_PROTOCOLS = listOf("2025-06-18", "2025-03-26", "2024-11-05")

private const val ERR_PARSE = -32700
private const val ERR_INVALID_REQUEST = -32600
private const val ERR_METHOD_NOT_FOUND = -32601
private const val ERR_INVALID_PARAMS = -32602
internal const val ERR_RATE_LIMITED = -32029

internal const val INSTRUCTIONS = """Fitlog 헬스 기록 서버입니다. / Fitlog workout log server.
- 모든 무게는 kg, 시각은 ISO-8601(시간대 포함), 날짜는 YYYY-MM-DD(사용자 시간대 기준, get_profile 의 timezone)입니다. / All weights are kg; times are ISO-8601; dates are YYYY-MM-DD in the user's timezone.
- 쓰기 도구는 충돌(같은 이름 종목, 같은 시각 세션, 필요한 TM 누락 등)이 없으면 바로 저장합니다. 충돌이 있으면 저장하지 않고 status NEEDS_RESOLUTION 과 충돌 목록(conflicts[].allowed)을 돌려주니, 사용자와 상의해 resolutions 에 해결 방법을 넣어 같은 묶음으로 다시 호출하세요. / Write tools save immediately when there are no conflicts; otherwise they return NEEDS_RESOLUTION with the conflicts and save nothing — retry the same bundle with resolutions.
- 저장된 묶음은 사용자가 앱의 AI 기록에서 되돌릴 수 있습니다. / Saved bundles can be reverted by the user in the app's AI history.
- 데이터를 직접 지울 수 없습니다. 삭제는 request_deletion 으로 요청만 만들고, 사용자가 앱에서 승인해야 실행됩니다. / You cannot delete data; request_deletion only creates a request the user must approve in the app.
- 프로그램 계산(무게·진행)은 서버 엔진이 합니다. get_plan 으로 계획을 읽기만 하세요. / Program math is done by the server; read plans with get_plan."""

/** 슬라이딩 윈도 호출 한도 (메모리) */
internal class SlidingWindow(private val limit: Int, private val windowMs: Long, private val now: () -> Long = System::currentTimeMillis) {
    private val hits = ConcurrentHashMap<UUID, ArrayDeque<Long>>()

    fun tryAcquire(key: UUID): Boolean {
        val t = now()
        val q = hits.computeIfAbsent(key) { ArrayDeque() }
        synchronized(q) {
            while (q.isNotEmpty() && q.peekFirst() <= t - windowMs) q.pollFirst()
            if (q.size >= limit) return false
            q.addLast(t)
            return true
        }
    }
}


private fun rpcError(id: JsonElement?, code: Int, message: String): JsonObject = buildJsonObject {
    put("jsonrpc", "2.0")
    put("id", id ?: JsonNull)
    put("error", buildJsonObject { put("code", code); put("message", message) })
}

private fun rpcResult(id: JsonElement?, result: JsonElement): JsonObject = buildJsonObject {
    put("jsonrpc", "2.0")
    put("id", id ?: JsonNull)
    put("result", result)
}

private val ALL_TOOLS: List<Tool> = READ_TOOLS + WRITE_TOOLS
private val TOOLS_BY_NAME = ALL_TOOLS.associateBy { it.name }

private fun toolJson(t: Tool): JsonObject = buildJsonObject {
    put("name", t.name)
    put("title", t.title)
    put(
        "description",
        t.description + if (t.write) " [필요 권한/Requires: $SCOPE_WRITE]" else " [필요 권한/Requires: $SCOPE_READ]",
    )
    put("inputSchema", t.input)
    put("outputSchema", t.output)
    put("annotations", buildJsonObject {
        put("title", t.title)
        put("readOnlyHint", !t.write)
        put("destructiveHint", false)
        put("idempotentHint", if (t.write) t.idempotent else true)
        put("openWorldHint", false)
    })
}

private val TOOLS_LIST: JsonArray = JsonArray(ALL_TOOLS.map(::toolJson))

private fun errorText(e: ApiException): String = buildString {
    append(e.message)
    if (e.field != null) append(" (").append(e.field).append(")")
    e.details?.take(20)?.forEach { append("\n- ").append(it.path).append(": ").append(it.message) }
}

/** A2 소유 (v0.3). 등록 위치: 루트(/mcp), 자체 OAuth 토큰 인증. 사양 2025-06-18 Streamable HTTP(JSON 응답만) */
fun Route.mcpRoutes(config: AppConfig) {
    // 세션 ID 는 서명된 토큰(연결 ID 포함)이라 서버가 재시작·재배포돼도(무료 호스팅은 자주 잠든다) 그대로 통한다.
    // 메모리 맵은 DELETE 로 닫은 세션을 거절하는 데만 쓴다
    val closedSessions = ConcurrentHashMap<String, Long>()
    val sessionSecret = config.jwt.secret
    fun sessionValid(sid: String, connectionId: UUID): Boolean {
        if (closedSessions.containsKey(sid)) return false
        val v = Signer.verify(sessionSecret, "mcpsid", sid) ?: return false
        return v["cid"] == connectionId.toString()
    }
    val callLimiter = SlidingWindow(60, 60_000)
    val writeLimiter = SlidingWindow(20, 60_000)
    val metadataUrl = "${config.publicBaseUrl}/.well-known/oauth-protected-resource"

    suspend fun ApplicationCall.rpc(status: HttpStatusCode, body: JsonElement) =
        respondText(body.toString(), ContentType.Application.Json, status)

    suspend fun ApplicationCall.unauthorized() {
        // 토큰을 보냈는데 거절된 경우(만료·폐기)는 error="invalid_token" 을 붙여 클라이언트가 갱신하게 한다(RFC 6750)
        val presented = request.header(HttpHeaders.Authorization) != null
        response.header(
            HttpHeaders.WWWAuthenticate,
            "Bearer " + (if (presented) "error=\"invalid_token\", " else "") + "resource_metadata=\"$metadataUrl\"",
        )
        respondText(
            buildJsonObject { put("error", "unauthorized"); put("error_description", "missing, invalid or revoked access token") }.toString(),
            ContentType.Application.Json, HttpStatusCode.Unauthorized,
        )
    }

    suspend fun authenticate(call: ApplicationCall): McpPrincipal? {
        val h = call.request.header(HttpHeaders.Authorization) ?: return null
        if (!h.startsWith("Bearer ", ignoreCase = true)) return null
        val token = h.substring(7).trim()
        if (token.isEmpty()) return null
        return OAuthTokenService.authenticate(token)
    }

    suspend fun logCall(p: McpPrincipal, tool: String, code: String, startNs: Long) {
        try {
            val ms = ((System.nanoTime() - startNs) / 1_000_000).toInt()
            dbQuery {
                AiToolCalls.insert {
                    it[connectionId] = p.connectionId
                    it[AiToolCalls.tool] = tool
                    it[resultCode] = code
                    it[durationMs] = ms
                    it[createdAt] = Times.now()
                }
            }
        } catch (e: Exception) {
            log.warn("ai_tool_call log failed: {}", e.toString())
        }
    }

    fun toolResult(text: String, data: JsonObject?, isError: Boolean): JsonObject = buildJsonObject {
        put("content", buildJsonArray { add(buildJsonObject { put("type", "text"); put("text", text) }) })
        if (data != null) put("structuredContent", data)
        put("isError", isError)
    }

    suspend fun callTool(config: AppConfig, p: McpPrincipal, id: JsonElement?, params: JsonObject?): JsonObject {
        val startNs = System.nanoTime()
        val name = (params?.get("name") as? JsonPrimitive)?.takeIf { it.isString }?.content
            ?: return rpcError(id, ERR_INVALID_PARAMS, "params.name is required")
        val tool = TOOLS_BY_NAME[name] ?: return rpcError(id, ERR_INVALID_PARAMS, "Unknown tool: $name")
        val argsEl = params["arguments"]
        if (argsEl != null && argsEl !is JsonObject && argsEl !is JsonNull) {
            return rpcError(id, ERR_INVALID_PARAMS, "params.arguments must be an object")
        }
        if (!callLimiter.tryAcquire(p.tokenId) || (tool.write && !writeLimiter.tryAcquire(p.tokenId))) {
            logCall(p, name, "RATE_LIMITED", startNs)
            return rpcError(id, ERR_RATE_LIMITED, "RATE_LIMITED")
        }
        if (tool.write && SCOPE_WRITE !in p.scopes) {
            logCall(p, name, "ERROR", startNs)
            return rpcResult(
                id,
                toolResult("권한 없음: 이 연결에는 쓰기 권한($SCOPE_WRITE)이 없습니다. 사용자가 앱에서 연결을 끊고 다시 연결하며 쓰기를 허용해야 합니다. / Permission denied: this connection has read-only access.", null, true),
            )
        }
        var code = "OK"
        val result = try {
            val out = tool.run(ToolCtx(config, p), Args((argsEl as? JsonObject) ?: JsonObject(emptyMap())))
            code = out.code
            toolResult(out.text, out.data, false)
        } catch (e: ApiException) {
            code = if (e.code == ErrorCode.VALIDATION_FAILED) "VALIDATION_FAILED" else "ERROR"
            toolResult(errorText(e), null, true)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            log.error("mcp tool {} failed", name, e)
            code = "ERROR"
            toolResult("서버 오류로 도구를 실행하지 못했습니다. / Internal error while running the tool.", null, true)
        }
        logCall(p, name, code, startNs)
        return rpcResult(id, result)
    }

    route("/mcp") {
        post {
            val call = this.call
            val principal = authenticate(call) ?: return@post call.unauthorized()

            val body = try {
                Json.parseToJsonElement(call.receiveText())
            } catch (e: Exception) {
                return@post call.rpc(HttpStatusCode.BadRequest, rpcError(null, ERR_PARSE, "Parse error"))
            }
            if (body is JsonArray) {
                return@post call.rpc(HttpStatusCode.BadRequest, rpcError(null, ERR_INVALID_REQUEST, "JSON-RPC batch is not supported"))
            }
            val msg = body as? JsonObject
                ?: return@post call.rpc(HttpStatusCode.BadRequest, rpcError(null, ERR_INVALID_REQUEST, "Invalid request"))
            val method = (msg["method"] as? JsonPrimitive)?.takeIf { it.isString }?.content
            if (method == null) {
                // 클라이언트가 보낸 응답(result/error)은 받기만 한다
                if (msg["result"] != null || msg["error"] != null) {
                    return@post call.respondText("", status = HttpStatusCode.Accepted)
                }
                return@post call.rpc(HttpStatusCode.BadRequest, rpcError(msg["id"], ERR_INVALID_REQUEST, "method is required"))
            }
            val id = msg["id"]?.takeIf { it !is JsonNull }
            val params = msg["params"] as? JsonObject

            if (method == "initialize") {
                if (id == null) return@post call.rpc(HttpStatusCode.BadRequest, rpcError(null, ERR_INVALID_REQUEST, "initialize must be a request"))
                val asked = (params?.get("protocolVersion") as? JsonPrimitive)?.contentOrNull
                val version = if (asked in SUPPORTED_PROTOCOLS) asked!! else LATEST_PROTOCOL
                val sid = Signer.sign(
                    sessionSecret, "mcpsid",
                    mapOf("cid" to principal.connectionId.toString(), "n" to UUID.randomUUID().toString()),
                    30L * 24 * 3600,
                )
                call.response.header("Mcp-Session-Id", sid)
                return@post call.rpc(
                    HttpStatusCode.OK,
                    rpcResult(id, buildJsonObject {
                        put("protocolVersion", version)
                        put("capabilities", buildJsonObject { put("tools", buildJsonObject { }) })
                        put("serverInfo", buildJsonObject { put("name", "fitlog"); put("title", "Fitlog"); put("version", "0.3.0") })
                        put("instructions", INSTRUCTIONS)
                    }),
                )
            }

            // initialize 이후 요청은 세션 헤더가 필요하다. 모르는 세션은 404(클라이언트가 다시 initialize)
            val sid = call.request.header("Mcp-Session-Id")
                ?: return@post call.rpc(HttpStatusCode.BadRequest, rpcError(id, ERR_INVALID_REQUEST, "Mcp-Session-Id header is required"))
            if (!sessionValid(sid, principal.connectionId)) {
                return@post call.rpc(HttpStatusCode.NotFound, rpcError(id, ERR_INVALID_REQUEST, "Unknown session; send initialize again"))
            }

            if (id == null) return@post call.respondText("", status = HttpStatusCode.Accepted) // 알림
            when (method) {
                "ping" -> call.rpc(HttpStatusCode.OK, rpcResult(id, buildJsonObject { }))
                "tools/list" -> call.rpc(HttpStatusCode.OK, rpcResult(id, buildJsonObject { put("tools", TOOLS_LIST) }))
                "tools/call" -> call.rpc(HttpStatusCode.OK, callTool(config, principal, id, params))
                else -> call.rpc(HttpStatusCode.OK, rpcError(id, ERR_METHOD_NOT_FOUND, "Method not found: $method"))
            }
        }

        // 서버가 먼저 보내는 SSE 스트림은 지원하지 않는다
        get {
            call.response.header(HttpHeaders.Allow, "POST, DELETE")
            call.respondText("", status = HttpStatusCode.MethodNotAllowed)
        }

        delete {
            val principal = authenticate(call) ?: return@delete call.unauthorized()
            val sid = call.request.header("Mcp-Session-Id")
            if (sid != null && sessionValid(sid, principal.connectionId)) {
                if (closedSessions.size > 50_000) closedSessions.clear()
                closedSessions[sid] = System.currentTimeMillis()
                call.respondText("", status = HttpStatusCode.OK)
            } else {
                call.respondText("", status = HttpStatusCode.NotFound)
            }
        }
    }
}
