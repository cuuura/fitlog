package com.fitlog.mcp

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.time.Instant
import java.util.ArrayDeque

/**
 * /mcp 요청 하나의 진단 기록. 토큰·연결/사용자 id·인자·결과는 담지 않는다.
 * ChatGPT 같은 외부 클라이언트가 실제로 무엇을 보내는지 로그를 못 볼 때 보려는 용도.
 */
internal class McpTraceRow(val httpMethod: String) {
    val at: Instant = Instant.now()
    /** /mcp 가 아닌 OAuth·메타데이터 요청일 때 경로 */
    var path: String? = null
    /** OAuth 요청의 진단용 값(파라미터 이름·redirect_uri 호스트·scope 등, 비밀 값 제외) */
    var detail: String? = null
    var rpcMethod: String = "-"
    var tool: String? = null
    var status: Int? = null
    var rpcError: Int? = null
    /** tools/call 결과의 isError */
    var toolError: Boolean? = null
    var client: String? = null
    var userAgent: String? = null
    var accept: String? = null
    var protocolVersion: String? = null
    var sessionPresent: Boolean = false
    /** 세션 헤더가 있을 때만 의미: 서명·연결·만료 검증 통과 여부 */
    var sessionVerified: Boolean? = null
    var authPresent: Boolean = false
    var authenticated: Boolean = false

    fun toJson(): JsonObject = buildJsonObject {
        put("at", at.toString())
        put("httpMethod", httpMethod)
        path?.let { put("path", it) }
        detail?.let { put("detail", it) }
        put("rpcMethod", rpcMethod)
        tool?.let { put("tool", it) }
        status?.let { put("status", it) }
        rpcError?.let { put("rpcError", it) }
        toolError?.let { put("toolError", it) }
        client?.let { put("client", it) }
        userAgent?.let { put("userAgent", it) }
        accept?.let { put("accept", it) }
        protocolVersion?.let { put("protocolVersion", it) }
        put("sessionPresent", sessionPresent)
        sessionVerified?.let { put("sessionVerified", it) }
        put("authPresent", authPresent)
        put("authenticated", authenticated)
    }

    fun logLine(): String =
        "mcp http=$httpMethod path=${path ?: "/mcp"} detail=${detail ?: "-"} rpc=$rpcMethod tool=${tool ?: "-"} status=${status ?: "-"} rpcError=${rpcError ?: "-"} " +
            "toolError=${toolError ?: "-"} client=${client ?: "-"} ua=${userAgent ?: "-"} accept=${accept ?: "-"} " +
            "proto=${protocolVersion ?: "-"} sid=${if (sessionPresent) "present" else "none"}/${sessionVerified ?: "-"} " +
            "auth=${if (authPresent) "present" else "none"}/${if (authenticated) "ok" else "no"}"
}

private val TRACE_BUFFER_KEY = io.ktor.util.AttributeKey<McpTraceBuffer>("fitlog.mcpTraceBuffer")

/** /mcp 와 OAuth·메타데이터 요청을 함께 담는 애플리케이션 단위 추적 버퍼 */
internal fun io.ktor.server.application.Application.mcpTraceBuffer(): McpTraceBuffer =
    attributes.computeIfAbsent(TRACE_BUFFER_KEY) { McpTraceBuffer(200) }

/** 최근 N건 링 버퍼 */
internal class McpTraceBuffer(private val capacity: Int = 100) {
    private val rows = ArrayDeque<McpTraceRow>()

    fun add(r: McpTraceRow) = synchronized(rows) {
        if (rows.size >= capacity) rows.pollFirst()
        rows.addLast(r)
    }

    /** 최신 것이 앞 */
    fun json(): JsonObject = synchronized(rows) {
        buildJsonObject {
            put("capacity", capacity)
            put("count", rows.size)
            put("entries", JsonArray(rows.descendingIterator().asSequence().map { it.toJson() }.toList()))
        }
    }
}

internal fun truncateUa(s: String?): String? = s?.replace(Regex("[\\r\\n]"), " ")?.take(120)

/** initialize 의 clientInfo 를 세션별로 잠깐 기억해 이후 행에도 클라이언트 이름을 붙인다(크기 제한) */
internal class ClientNames(private val max: Int = 500) {
    private val map = object : LinkedHashMap<String, String>(16, 0.75f, false) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, String>?) = size > max
    }

    fun put(sid: String, name: String) = synchronized(map) { map[sid] = name; Unit }
    fun get(sid: String): String? = synchronized(map) { map[sid] }
}

internal fun clientLabel(params: JsonObject?): String? {
    val info = params?.get("clientInfo") as? JsonObject ?: return null
    val n = (info["name"] as? JsonPrimitive)?.takeIf { it.isString }?.content?.take(60) ?: return null
    val v = (info["version"] as? JsonPrimitive)?.takeIf { it.isString }?.content?.take(30)
    return if (v != null) "$n/$v" else n
}
