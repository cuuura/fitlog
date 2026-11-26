package com.fitlog.importing

import com.fitlog.core.InstantSerializer
import com.fitlog.core.UUIDSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import java.time.Instant
import java.util.UUID

/*
 * 가져오기 파이프라인 공개 인터페이스와 DTO (트랙 리드 소유). contracts/v0.3 import.md, openapi.yaml.
 * 구현: ImportPipeline (A1). 사용: /v1/imports (A1), MCP 쓰기 도구 (A2), 내보내기 왕복 테스트 (A3).
 */

enum class ImportChannel { APP_JSON, MCP }

/** 누가 어떤 경로로 가져오는지. userId 는 항상 토큰에서 정한다 */
data class ImportContext(
    val userId: UUID,
    val channel: ImportChannel,
    /** MCP 는 OAuth 클라이언트 이름, 앱은 사용자가 고른 AI 이름 */
    val clientName: String? = null,
    val aiConnectionId: UUID? = null,
)

@Serializable
data class Resolution(
    val action: String, // SKIP, KEEP_BOTH, REPLACE, MAP_TO, CREATE, UNLINK, SET
    val exerciseId: String? = null,
    val exercise: JsonObject? = null,
    val value: JsonObject? = null,
)

/** openapi ImportRequest. bundle 은 검증 전 원문 */
@Serializable
data class ImportRequest(
    val bundle: JsonElement,
    val channel: String? = null,
    val clientName: String? = null,
    val tz: String? = null,
    val onConflict: String = "ASK",
    val resolutions: Map<String, Resolution> = emptyMap(),
)

@Serializable
data class ExerciseCandidate(val exerciseId: String, val nameKo: String, val nameEn: String? = null)

@Serializable
data class Conflict(
    val conflictId: String,
    val code: String,
    val path: String,
    val message: String,
    val allowed: List<String>,
    val existing: JsonObject? = null,
    val candidates: List<ExerciseCandidate>? = null,
    val suggested: JsonObject? = null,
)

@Serializable
data class ImportPreview(
    val valid: Boolean,
    val counts: Map<String, Map<String, Int>>,
    val conflicts: List<Conflict>,
    val unresolved: List<String> = emptyList(),
)

@Serializable
data class ImportBatch(
    @Serializable(with = UUIDSerializer::class) val id: UUID,
    @Serializable(with = InstantSerializer::class) val createdAt: Instant,
    val channel: String,
    val clientName: String? = null,
    val note: String? = null,
    val summary: Map<String, Int>,
    @Serializable(with = InstantSerializer::class) val revertedAt: Instant? = null,
)

sealed interface ImportOutcome {
    /** created=false 면 모든 항목 UNCHANGED (openapi 200) */
    data class Saved(val batch: ImportBatch, val created: Boolean) : ImportOutcome

    /** 해결 안 된 충돌이 있어 저장하지 않음 (openapi 409 CONFLICT_UNRESOLVED) */
    data class NeedsResolution(val preview: ImportPreview) : ImportOutcome
}

interface Importer {
    /** 저장 없이 검증·이름 해석·충돌 탐지. 스키마 위반은 ApiException(VALIDATION_FAILED, details) */
    suspend fun preview(ctx: ImportContext, req: ImportRequest): ImportPreview

    /** 가져오기. 한 트랜잭션. 스키마 위반은 ApiException(VALIDATION_FAILED, details) */
    suspend fun import(ctx: ImportContext, req: ImportRequest): ImportOutcome
}
