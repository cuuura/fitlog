# syntax=docker/dockerfile:1
# fitlog 서버 이미지. 빌드 컨텍스트는 저장소 루트(계약 md 를 jar 에 묶기 위해 contracts/ 가 필요).
#   docker build -f server/Dockerfile -t fitlog-server .

# ---- 빌드: installDist ----
FROM eclipse-temurin:21-jdk AS build
WORKDIR /src/server

# 의존성 레이어 캐시: 빌드 스크립트만 먼저 복사해 의존성을 받아 둔다
COPY server/gradlew server/settings.gradle.kts server/build.gradle.kts server/gradle.properties ./
COPY server/gradle ./gradle
RUN chmod +x gradlew && ./gradlew --no-daemon --console=plain dependencies > /dev/null 2>&1 || true

COPY server/src ./src
COPY contracts /src/contracts
RUN ./gradlew --no-daemon --console=plain installDist -x test

# ---- 실행 ----
FROM eclipse-temurin:21-jre
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --uid 10001 --home-dir /app --shell /usr/sbin/nologin fitlog
WORKDIR /app
COPY --from=build --chown=fitlog:fitlog /src/server/build/install/fitlog-server/ ./

USER fitlog
ENV PORT=8080 \
    JAVA_OPTS="-XX:MaxRAMPercentage=75 -XX:+ExitOnOutOfMemoryError"
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
    CMD curl -fsS "http://localhost:${PORT}/health/ready" || exit 1

# exec 형식이라 SIGTERM 이 JVM 에 바로 전달된다(graceful shutdown)
ENTRYPOINT ["/app/bin/fitlog-server"]
