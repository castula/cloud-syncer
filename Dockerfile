FROM alpine:latest

RUN apk add --no-cache curl jq yq tzdata ca-certificates

ENV TZ=Asia/Shanghai \
    CONFIG_FILE="/app/config/config.yaml"

WORKDIR /app

COPY config.example.yaml /app/config.example.yaml
COPY entrypoint.sh /app/entrypoint.sh
COPY sync_task.sh /app/sync_task.sh

RUN chmod +x /app/entrypoint.sh /app/sync_task.sh && \
    mkdir -p /app/config /backups /tmp/syncer_state

ENTRYPOINT ["/app/entrypoint.sh"]
