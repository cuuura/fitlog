package com.fitlog.importing

import java.util.UUID

/*
 * Strong·Hevy 가 쓰는 영어 종목 이름 → 기본 제공 종목(V2 시드) 사전.
 * 키는 이름을 정규화한 값(대소문자·괄호·하이픈·단어 순서·복수형 차이를 없앰)이다. 위치: 서버 코드(계약 9.5).
 */
internal object CsvExerciseDictionary {
    private const val SEED_PREFIX = "019b76da-4000-7000-8000-"

    /** 시드 종목 id. index 는 V2 시드의 마지막 자리(1 = ...0001) */
    fun seedId(index: Int): UUID = UUID.fromString(SEED_PREFIX + "%012x".format(index))

    /** 정규화: 괄호 안 단어(기구 표기)와 바깥 단어를 나눠 각각 소문자 단어 집합(정렬)으로 만든다 */
    class Norm(val full: String, val base: String, val parenWords: Set<String>)

    private fun words(s: String): List<String> =
        s.lowercase().replace(Regex("[^a-z0-9]+"), " ").trim().split(' ').filter { it.isNotEmpty() }
            .map { if (it.length > 3 && it.endsWith("s") && !it.endsWith("ss")) it.dropLast(1) else it }

    fun normalize(name: String): Norm {
        val parens = Regex("\\(([^)]*)\\)").findAll(name).flatMap { words(it.groupValues[1]) }.toList()
        val outside = words(name.replace(Regex("\\([^)]*\\)"), " "))
        return Norm(
            (outside + parens).sorted().joinToString(" "),
            outside.sorted().joinToString(" "),
            parens.toSet(),
        )
    }

    /** 괄호에 이 단어가 있으면 기구가 달라지는 것이므로 괄호 없는 이름으로 되돌려 찾지 않는다 */
    private val EQUIPMENT_WORDS = setOf("barbell", "dumbbell", "machine", "smith", "band", "kettlebell", "plate", "assisted")

    /** 사전·사용자 종목 같은 "정규화 키 → 값" 맵에서 찾는다: 전체 이름 먼저, 기구가 바뀌지 않으면 괄호 없는 이름 */
    fun <T> find(map: Map<String, T>, n: Norm): T? =
        map[n.full] ?: if (n.parenWords.none { it in EQUIPMENT_WORDS }) map[n.base] else null

    private val SEED: Map<Int, List<String>> = mapOf(
        0x01 to listOf("Squat", "Squat (Barbell)", "Back Squat", "Barbell Squat", "Barbell Back Squat", "Back Squat (Barbell)", "High Bar Squat", "Low Bar Squat"),
        0x02 to listOf("Front Squat", "Front Squat (Barbell)", "Barbell Front Squat"),
        0x03 to listOf("Bench Press", "Bench Press (Barbell)", "Barbell Bench Press", "Flat Bench Press", "Flat Bench Press (Barbell)"),
        0x04 to listOf("Incline Bench Press", "Incline Bench Press (Barbell)", "Barbell Incline Bench Press"),
        0x05 to listOf("Decline Bench Press", "Decline Bench Press (Barbell)"),
        0x06 to listOf("Deadlift", "Deadlift (Barbell)", "Barbell Deadlift", "Conventional Deadlift"),
        0x07 to listOf("Romanian Deadlift", "Romanian Deadlift (Barbell)", "RDL"),
        0x08 to listOf("Sumo Deadlift", "Sumo Deadlift (Barbell)"),
        0x09 to listOf("Overhead Press", "Overhead Press (Barbell)", "Military Press", "Shoulder Press (Barbell)", "Standing Overhead Press", "OHP", "Barbell Overhead Press"),
        0x0a to listOf("Barbell Row", "Bent Over Row", "Bent Over Row (Barbell)", "Row (Barbell)", "Bent Over Barbell Row"),
        0x0b to listOf("Pendlay Row", "Pendlay Row (Barbell)"),
        0x0c to listOf("Barbell Curl", "Bicep Curl (Barbell)", "Biceps Curl (Barbell)", "Curl (Barbell)", "EZ Bar Biceps Curl", "EZ Bar Curl"),
        0x0d to listOf("Hip Thrust", "Hip Thrust (Barbell)", "Barbell Hip Thrust"),
        0x0e to listOf("Close-Grip Bench Press", "Close Grip Bench Press (Barbell)", "Bench Press - Close Grip (Barbell)"),
        0x0f to listOf("Barbell Lunge", "Lunge (Barbell)"),
        0x10 to listOf("Good Morning", "Good Morning (Barbell)"),
        0x11 to listOf("Barbell Shrug", "Shrug (Barbell)"),
        0x12 to listOf("Skull Crusher", "Skullcrusher", "Skull Crusher (Barbell)", "Skullcrusher (Barbell)", "Lying Triceps Extension", "Lying Triceps Extension (Barbell)"),
        0x13 to listOf("Dumbbell Bench Press", "Bench Press (Dumbbell)", "Dumbbell Press"),
        0x14 to listOf("Incline Dumbbell Press", "Incline Bench Press (Dumbbell)", "Incline Chest Press (Dumbbell)", "Incline Dumbbell Bench Press"),
        0x15 to listOf("Dumbbell Row", "Bent Over Row (Dumbbell)", "One Arm Dumbbell Row", "Single Arm Row (Dumbbell)", "Row (Dumbbell)"),
        0x16 to listOf("Dumbbell Shoulder Press", "Shoulder Press (Dumbbell)", "Seated Shoulder Press (Dumbbell)", "Overhead Press (Dumbbell)", "Seated Dumbbell Shoulder Press"),
        0x17 to listOf("Lateral Raise", "Lateral Raise (Dumbbell)", "Side Lateral Raise", "Side Lateral Raise (Dumbbell)", "Dumbbell Lateral Raise"),
        0x18 to listOf("Rear Delt Fly", "Rear Delt Fly (Dumbbell)", "Reverse Fly (Dumbbell)", "Rear Delt Reverse Fly (Dumbbell)"),
        0x19 to listOf("Dumbbell Curl", "Bicep Curl (Dumbbell)", "Biceps Curl (Dumbbell)", "Curl (Dumbbell)"),
        0x1a to listOf("Hammer Curl", "Hammer Curl (Dumbbell)"),
        0x1b to listOf("Incline Dumbbell Curl", "Incline Curl (Dumbbell)", "Incline Bicep Curl (Dumbbell)"),
        0x1c to listOf("Dumbbell Lunge", "Lunge (Dumbbell)", "Walking Lunge (Dumbbell)"),
        0x1d to listOf("Bulgarian Split Squat", "Bulgarian Split Squat (Dumbbell)"),
        0x1e to listOf("Goblet Squat", "Goblet Squat (Dumbbell)", "Goblet Squat (Kettlebell)"),
        0x1f to listOf("Dumbbell Triceps Extension", "Triceps Extension (Dumbbell)", "Overhead Triceps Extension (Dumbbell)"),
        0x20 to listOf("Dumbbell Fly", "Chest Fly (Dumbbell)", "Fly (Dumbbell)"),
        0x21 to listOf("Dumbbell Shrug", "Shrug (Dumbbell)"),
        0x22 to listOf("Dumbbell Romanian Deadlift", "Romanian Deadlift (Dumbbell)"),
        0x23 to listOf("Front Raise", "Front Raise (Dumbbell)"),
        0x24 to listOf("Dumbbell Pullover", "Pullover (Dumbbell)"),
        0x25 to listOf("Leg Press", "Leg Press (Machine)", "Leg Press Horizontal (Machine)"),
        0x26 to listOf("Leg Extension", "Leg Extension (Machine)"),
        0x27 to listOf("Leg Curl", "Leg Curl (Machine)", "Lying Leg Curl (Machine)", "Seated Leg Curl (Machine)", "Hamstring Curl (Machine)"),
        0x28 to listOf("Lat Pulldown", "Lat Pulldown (Cable)", "Lat Pulldown (Machine)"),
        0x29 to listOf("Seated Cable Row", "Seated Row (Cable)", "Cable Row", "Seated Row"),
        0x2a to listOf("Cable Fly", "Cable Crossover", "Chest Fly (Cable)", "Cable Fly Crossovers"),
        0x2b to listOf("Chest Press Machine", "Chest Press (Machine)", "Machine Chest Press"),
        0x2c to listOf("Pec Deck Fly", "Pec Deck (Machine)", "Butterfly (Pec Deck)", "Chest Fly (Machine)"),
        0x2d to listOf("Triceps Pushdown", "Triceps Pushdown (Cable)", "Tricep Pushdown", "Triceps Rope Pushdown", "Triceps Pushdown (Cable - Straight Bar)"),
        0x2e to listOf("Face Pull", "Face Pull (Cable)"),
        0x2f to listOf("Calf Raise", "Standing Calf Raise", "Standing Calf Raise (Machine)", "Seated Calf Raise (Machine)", "Calf Raise (Machine)", "Calf Press (Machine)"),
        0x30 to listOf("Hack Squat", "Hack Squat (Machine)"),
        0x31 to listOf("Smith Machine Squat", "Squat (Smith Machine)"),
        0x32 to listOf("Shoulder Press Machine", "Shoulder Press (Machine)", "Machine Shoulder Press"),
        0x33 to listOf("Seated Row Machine", "Seated Row (Machine)", "Iso-Lateral Row (Machine)"),
        0x34 to listOf("Reverse Pec Deck", "Rear Delt Reverse Fly (Machine)", "Reverse Fly (Machine)"),
        0x35 to listOf("Hip Abduction Machine", "Hip Abduction (Machine)", "Thigh Abductor (Machine)"),
        0x36 to listOf("Hip Adduction Machine", "Hip Adduction (Machine)", "Thigh Adductor (Machine)"),
        0x37 to listOf("Cable Curl", "Bicep Curl (Cable)", "Biceps Curl (Cable)"),
        0x38 to listOf("Overhead Cable Triceps Extension", "Triceps Extension (Cable)", "Overhead Triceps Extension (Cable)"),
        0x39 to listOf("Cable Crunch", "Crunch (Cable)", "Kneeling Cable Crunch"),
        0x3a to listOf("Smith Machine Bench Press", "Bench Press (Smith Machine)"),
        0x3b to listOf("Assisted Pull-Up Machine", "Assisted Pull Up", "Pull Up (Assisted)", "Chin Up (Assisted)"),
        0x3c to listOf("Pull-Up", "Pull Up", "Pullups"),
        0x3d to listOf("Chin-Up", "Chin Up"),
        0x3e to listOf("Dips", "Dip", "Triceps Dip", "Chest Dip"),
        0x3f to listOf("Push-Up", "Push Up", "Pushups"),
        0x40 to listOf("Hanging Leg Raise", "Hanging Knee Raise"),
        0x41 to listOf("Back Extension", "Back Extension (Hyperextension)", "Hyperextension"),
        0x42 to listOf("Crunch", "Crunches"),
        0x43 to listOf("Sit-Up", "Sit Up", "Situps"),
        0x44 to listOf("Bodyweight Squat", "Air Squat", "Squat (Bodyweight)"),
        0x45 to listOf("Lunge", "Lunge (Bodyweight)", "Walking Lunge"),
        0x46 to listOf("Lying Leg Raise", "Leg Raise"),
        0x47 to listOf("Band Pull-Apart", "Band Pull Apart", "Pull Apart (Band)"),
        0x48 to listOf("Band Pushdown", "Triceps Pushdown (Band)"),
        0x49 to listOf("Band Curl", "Bicep Curl (Band)"),
        0x4a to listOf("Running", "Run", "Treadmill", "Running (Outdoor)", "Running (Treadmill)"),
        0x4b to listOf("Cycling", "Cycling (Indoor)", "Cycling (Outdoor)", "Bike", "Stationary Bike"),
        0x4c to listOf("Rowing Machine", "Rowing", "Rowing (Machine)"),
        0x4d to listOf("Stair Climber", "Stairmaster", "Stair Machine"),
    )

    /** 시드에 없는 흔한 종목의 주동근(새 종목으로 만들 때 쓴다). 모르면 FULL_BODY */
    private val EXTRA_MUSCLE: Map<String, String> = mapOf(
        "Preacher Curl" to "BICEPS", "Concentration Curl" to "BICEPS", "Reverse Curl" to "FOREARMS", "Wrist Curl" to "FOREARMS",
        "Arnold Press" to "SHOULDERS", "Upright Row" to "SHOULDERS", "Cable Lateral Raise" to "SHOULDERS",
        "T Bar Row" to "BACK", "Trap Bar Deadlift" to "BACK", "Stiff Leg Deadlift" to "HAMSTRINGS",
        "Cable Pull Through" to "GLUTES", "Glute Bridge" to "GLUTES", "Step Up" to "QUADS",
        "Plank" to "ABS", "Ab Wheel" to "ABS", "Russian Twist" to "OBLIQUES", "Chest Supported Row" to "BACK",
        "Single Leg Press" to "QUADS", "Tricep Kickback" to "TRICEPS",
    )

    private val seedByKey: Map<String, Int> = buildMap {
        SEED.forEach { (idx, names) -> names.forEach { putIfAbsent(normalize(it).full, idx) } }
    }
    private val extraByKey: Map<String, String> = EXTRA_MUSCLE.entries.associate { normalize(it.key).full to it.value }

    /** 사전에 있는 이름 수(테스트용) */
    val size: Int get() = SEED.values.sumOf { it.size } + EXTRA_MUSCLE.size

    fun seedFor(n: Norm): Int? = find(seedByKey, n)

    /** 시드가 아닌 새 종목의 주동근. 사전에 없으면 FULL_BODY */
    fun muscleFor(n: Norm): String = find(extraByKey, n) ?: "FULL_BODY"
}
