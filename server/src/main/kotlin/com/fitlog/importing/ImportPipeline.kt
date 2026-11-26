package com.fitlog.importing

/** A1 소유. import.md 파이프라인 구현 */
object ImportPipeline : Importer {
    override suspend fun preview(ctx: ImportContext, req: ImportRequest): ImportPreview = TODO("A1")
    override suspend fun import(ctx: ImportContext, req: ImportRequest): ImportOutcome = TODO("A1")
}
