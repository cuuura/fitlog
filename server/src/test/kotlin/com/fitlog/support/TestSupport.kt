package com.fitlog.support

import com.fitlog.core.AccessTokens
import com.fitlog.core.AppConfig
import com.fitlog.core.AppJson
import com.fitlog.core.AppUsers
import com.fitlog.core.DbConfig
import com.fitlog.core.Ids
import com.fitlog.core.JwtConfig
import com.fitlog.core.Times
import com.fitlog.module
import io.ktor.client.HttpClient
import io.ktor.client.plugins.contentnegotiation.ContentNegotiation
import io.ktor.client.request.HttpRequestBuilder
import io.ktor.client.request.header
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.contentType
import io.ktor.serialization.kotlinx.json.json
import io.ktor.server.testing.ApplicationTestBuilder
import io.ktor.server.testing.testApplication
import org.jetbrains.exposed.sql.insert
import org.jetbrains.exposed.sql.transactions.transaction
import java.util.UUID

/**
 * 통합 테스트 공용 도구 (트랙 리드 소유).
 * 로컬 PostgreSQL 필요: FITLOG_TEST_DB_URL (기본 jdbc:postgresql://localhost:5432/fitlog_test, fitlog/fitlog)
 * 테스트끼리 DB를 비우지 않는다. 각 테스트는 createUser()로 새 사용자를 만들어 격리한다.
 */
object TestEnv {
    val config = AppConfig(
        port = 0,
        db = DbConfig(
            url = System.getenv("FITLOG_TEST_DB_URL") ?: "jdbc:postgresql://localhost:5432/fitlog_test",
            user = System.getenv("FITLOG_TEST_DB_USER") ?: "fitlog",
            password = System.getenv("FITLOG_TEST_DB_PASSWORD") ?: "fitlog",
            maxPool = 4,
        ),
        jwt = JwtConfig(secret = "test-secret-test-secret-test-secret"),
        googleClientIds = listOf("test-client-id"),
    )
    val tokens = AccessTokens(config.jwt)
}

fun fitlogTest(block: suspend ApplicationTestBuilder.() -> Unit) = testApplication {
    application { module(TestEnv.config) }
    block()
}

/** JSON 직렬화가 설정된 클라이언트 */
fun ApplicationTestBuilder.jsonClient(): HttpClient = createClient {
    install(ContentNegotiation) { json(AppJson) }
}

/** DB에 사용자를 직접 만들고 ID를 돌려준다 (module()이 먼저 DB를 초기화해야 하므로 요청 한 번 이후 또는 startApplication() 후 호출) */
fun createUser(email: String = "u-${UUID.randomUUID()}@test.local"): UUID {
    val id = Ids.newId()
    transaction {
        AppUsers.insert {
            it[AppUsers.id] = id
            it[googleSub] = "sub-$id"
            it[AppUsers.email] = email
            it[displayName] = "Test"
            it[role] = "MEMBER"
            it[createdAt] = Times.now()
            it[updatedAt] = Times.now()
        }
    }
    return id
}

fun HttpRequestBuilder.auth(userId: UUID) {
    header(HttpHeaders.Authorization, "Bearer ${TestEnv.tokens.issue(userId)}")
}

fun HttpRequestBuilder.jsonBody() = contentType(ContentType.Application.Json)
