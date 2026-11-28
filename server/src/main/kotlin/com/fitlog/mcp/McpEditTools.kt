package com.fitlog.mcp

import com.fitlog.core.AppJson
import com.fitlog.core.dbQuery
import com.fitlog.core.validation
import com.fitlog.program.catalog.updateProgram
import com.fitlog.program.instance.Instance
import com.fitlog.program.instance.SwapLift
import com.fitlog.program.instance.programAnalysis
import com.fitlog.program.instance.replaceInstanceDefinition
import com.fitlog.program.instance.swapInstanceLift
import com.fitlog.program.instance.validateDefinition
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.encodeToJsonElement
import kotlinx.serialization.json.put

/*
 * v1.2 AI-4 도구(edit.md 7절). 분석·제안은 AI 가 대화에서 하고, 서버는 데이터와 바꾸는 도구만 준다.
 * 바꾸는 도구의 설명에는 "사용자에게 먼저 보여 주고 동의를 받은 뒤 호출" 을 적는다.
 */

private val idS = S.str("UUID", format = "uuid")

private const val CONSENT_KO = "바꿀 내용을 사용자에게 먼저 보여 주고 동의를 받은 뒤 호출하세요."
private const val CONSENT_EN = "Show the user what will change and get their consent before calling."

internal val EDIT_READ_TOOLS: List<Tool> = listOf(
    Tool(
        name = "get_program_analysis", title = "프로그램 진행 분석",
        description = "진행 중인 프로그램의 종목 키별 상태(TM·작업 무게·실패 연속·정체 여부·회차별 값 이력)와 최근 회차의 계획 대비 실제 기록, 수행률을 조회합니다. 분석과 조정 제안에 쓰세요. / Get per-lift progression state, stall flags, recent plan-vs-actual sessions and adherence for a program instance.",
        write = false,
        input = S.obj(
            "instanceId" to idS, "sessions" to S.int("최근 회차 수. 기본 8, 1~20", 1, 20),
            required = listOf("instanceId"),
        ),
        output = S.obj(
            "analysis" to S.anyObj(
                "lifts[{key, exerciseId, exerciseName, ruleType, tm, working, failStreak, stalled, history[{planSeq,date,value,result}]}], " +
                    "recentSessions[{planSeq,date,dayName,exercises[{liftKey,planned[],actual[],hit}]}], adherence{completed,skipped,last28Days}",
            ),
            required = listOf("analysis"),
        ),
        run = { ctx, a ->
            val id = a.uuid("instanceId")
            val n = a.int("sessions", 1, 20, 8)!!
            val analysis = dbQuery { programAnalysis(ctx.config.engine, ctx.userId, id, n) }
            val lifts = analysis["lifts"]?.let { (it as kotlinx.serialization.json.JsonArray).size } ?: 0
            ToolOutput("프로그램 분석: 종목 키 ${lifts}개, 최근 ${n}회차 기준", buildJsonObject { put("analysis", analysis) })
        },
    ),
)

internal val EDIT_WRITE_TOOLS: List<Tool> = listOf(
    Tool(
        name = "update_program", title = "프로그램 정의 고치기",
        description = "내 프로그램의 정의를 검증해 고칩니다(기본 템플릿은 불가). 진행 중인 인스턴스는 바뀌지 않으며 응답의 activeInstanceIds 에 edit_program_instance 로 따로 적용합니다. $CONSENT_KO / Edit my program definition (built-in templates are read-only); running instances are unchanged. $CONSENT_EN",
        write = true,
        input = S.obj(
            "programId" to idS,
            "definition" to S.anyObj("program.schema.json 형식 전체. 스키마: /v1/public/schema/program.json"),
            "name" to S.str("바꿀 이름(선택). 없으면 definition.name"),
            required = listOf("programId", "definition"),
        ),
        output = S.obj(
            "program" to S.anyObj("Program + activeInstanceIds"), "message" to S.str(),
            required = listOf("program"),
        ),
        idempotent = true,
        run = { ctx, a ->
            val id = a.uuid("programId")
            val def = a.obj("definition", required = true)!!
            val name = a.str("name", max = 200)
            val program = updateProgram(ctx.userId, id, name, def)
            val active = (program["activeInstanceIds"] as? kotlinx.serialization.json.JsonArray)?.size ?: 0
            ToolOutput(
                "프로그램 '${(program["name"] as? JsonPrimitive)?.content}' 을(를) 고쳤습니다. 진행 중 인스턴스 ${active}개는 그대로입니다.",
                buildJsonObject {
                    put("program", program)
                    put("message", "정의를 고쳤습니다. 진행 중인 인스턴스에 적용하려면 edit_program_instance 를 호출하세요.")
                },
            )
        },
    ),
    Tool(
        name = "edit_program_instance", title = "진행 중 프로그램 고치기",
        description = "진행 중인 프로그램 인스턴스에 새 정의(definition)를 적용하거나 종목 하나를 바꿉니다(swap). 다음 회차부터 적용되고 지난 기록은 다시 판정되지 않습니다. definition 과 swap 중 하나만 주세요. 새로 필요한 TM·작업 무게는 tm·working 으로 주세요. $CONSENT_KO / Apply a new definition or swap one lift on a running program instance, effective from the next session (exactly one of definition or swap). $CONSENT_EN",
        write = true,
        input = S.obj(
            "instanceId" to idS,
            "definition" to S.anyObj("program.schema.json 형식 전체(swap 과 함께 쓸 수 없음)"),
            "swap" to S.obj(
                "liftKey" to S.str("바꿀 종목 키"), "exerciseId" to idS,
                required = listOf("liftKey", "exerciseId"), desc = "종목 하나 교체(definition 과 함께 쓸 수 없음)",
            ),
            "tm" to S.map(S.num(min = 0.0), "종목 키 → TM(kg)"),
            "working" to S.map(S.num(min = 0.0), "종목 키 → 작업 무게(kg)"),
            required = listOf("instanceId"),
        ),
        output = S.obj("instance" to S.anyObj("Instance"), "message" to S.str(), required = listOf("instance")),
        idempotent = true,
        run = { ctx, a ->
            val id = a.uuid("instanceId")
            val defEl = a.obj("definition")
            val swapEl = a.obj("swap")
            if ((defEl == null) == (swapEl == null)) validation("exactly one of definition or swap is required", "definition")
            val tm = a.numMap("tm")
            val working = a.numMap("working")
            val inst: Instance = if (defEl != null) {
                val def = validateDefinition(ctx.userId, defEl)
                dbQuery { replaceInstanceDefinition(ctx.config.engine, ctx.userId, id, def, tm, working) }
            } else {
                val liftKey = swapEl!!["liftKey"]?.let { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content }
                    ?: validation("swap.liftKey is required", "swap.liftKey")
                val exerciseId = swapEl["exerciseId"]?.let { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content }
                    ?.let { com.fitlog.core.Ids.parse(it, "swap.exerciseId") }
                    ?: validation("swap.exerciseId is required", "swap.exerciseId")
                dbQuery { swapInstanceLift(ctx.config.engine, ctx.userId, id, SwapLift(liftKey, exerciseId, tm[liftKey], working[liftKey])) }
            }
            ToolOutput(
                "프로그램 '${inst.name}' 에 적용했습니다. 다음 회차부터 반영됩니다.",
                buildJsonObject {
                    put("instance", AppJson.encodeToJsonElement(inst) as JsonObject)
                    put("message", "다음 회차부터 적용됩니다. 지난 기록은 다시 판정되지 않습니다.")
                },
            )
        },
    ),
)
