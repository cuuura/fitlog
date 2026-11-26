package com.fitlog.core

import com.zaxxer.hikari.HikariConfig
import com.zaxxer.hikari.HikariDataSource
import kotlinx.coroutines.Dispatchers
import org.flywaydb.core.Flyway
import org.jetbrains.exposed.sql.Transaction
import org.jetbrains.exposed.sql.transactions.experimental.newSuspendedTransaction
import javax.sql.DataSource
import org.jetbrains.exposed.sql.Database as ExposedDb

object Database {
    private var ds: HikariDataSource? = null

    val dataSource: DataSource get() = ds ?: error("Database not initialised")

    @Synchronized
    fun init(cfg: DbConfig) {
        if (ds != null) return
        val pool = HikariDataSource(HikariConfig().apply {
            jdbcUrl = cfg.url
            username = cfg.user
            password = cfg.password
            maximumPoolSize = cfg.maxPool
            isAutoCommit = false
            transactionIsolation = "TRANSACTION_READ_COMMITTED"
        })
        Flyway.configure().dataSource(pool).locations("classpath:db/migration").load().migrate()
        ExposedDb.connect(pool)
        ds = pool
    }

    /** 서버 종료 시 커넥션 풀을 닫는다(main 에서 ApplicationStopped 에 연결). 다시 init 하면 새 풀을 만든다 */
    @Synchronized
    fun close() {
        ds?.close()
        ds = null
    }
}

/** 모든 DB 접근은 이 함수로 한다 */
suspend fun <T> dbQuery(block: suspend Transaction.() -> T): T =
    newSuspendedTransaction(Dispatchers.IO) { block() }
