package com.fitlog.core

import org.jetbrains.exposed.sql.Transaction
import java.util.UUID

/**
 * 사용자 단위 쓰기 직렬화. 동기화 대상 테이블(exercise, workout_session, session_exercise,
 * workout_set, body_measurement)에 쓰는 트랜잭션은 첫 쓰기 전에 반드시 호출한다.
 * 같은 사용자의 server_seq 가 커밋 순서대로 매겨져 pull 에서 변경을 놓치지 않는다.
 * 트랜잭션이 끝나면 자동 해제된다.
 */
fun Transaction.lockUser(userId: UUID) {
    val key = userId.mostSignificantBits xor userId.leastSignificantBits
    exec("SELECT pg_advisory_xact_lock($key)")
}
