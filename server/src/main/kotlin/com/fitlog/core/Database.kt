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
    lateinit var dataSource: DataSource
        private set

    fun init(cfg: DbConfig) {
        if (::dataSource.isInitialized) return
        val ds = HikariDataSource(HikariConfig().apply {
            jdbcUrl = cfg.url
            username = cfg.user
            password = cfg.password
            maximumPoolSize = cfg.maxPool
            isAutoCommit = false
            transactionIsolation = "TRANSACTION_READ_COMMITTED"
        })
        Flyway.configure().dataSource(ds).locations("classpath:db/migration").load().migrate()
        ExposedDb.connect(ds)
        dataSource = ds
    }
}

/** 모든 DB 접근은 이 함수로 한다 */
suspend fun <T> dbQuery(block: suspend Transaction.() -> T): T =
    newSuspendedTransaction(Dispatchers.IO) { block() }
