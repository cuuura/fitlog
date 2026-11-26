# 일일 백업 컨테이너: postgres:16 클라이언트 도구 + curl(웹훅) + 스크립트
FROM postgres:16
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*
COPY backup.sh backup-loop.sh restore.sh restore-check.sh /scripts/
RUN chmod +x /scripts/*.sh
ENTRYPOINT ["/scripts/backup-loop.sh"]
