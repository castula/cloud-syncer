#!/bin/sh

# ==============================================================================
# 单任务同步与校验核心脚本
# 功能：
#   1. 支持 4 种同步模式：r2、gist、webdav、url (HTTP/HTTPS直链)
#   2. 向下兼容旧版配置文件字段（自动兜底默认值）
#   3. 执行完整性校验、不可见字符清洗与多格式语法校验（JSON/YAML/TOML）
#   4. 备份原文件到 /backups 目录（覆盖旧备份）并执行文件同步更新
#   5. 触发后置动作、容器存活检查、故障自动回滚及 Webhook 通知推送
# ==============================================================================

TASK_INDEX="$1"
STATE_DIR="/tmp/syncer_state"
BACKUP_DIR="/backups"

if [ -z "$TASK_INDEX" ]; then
    echo "[ERROR] 缺少任务索引参数 (用法: /app/sync_task.sh 0)"
    exit 1
fi

# ------------------------------------------------------------------------------
# 读取全局与当前任务配置（均带有 // 默认值兜底，确保老版本 config 升级镜像后不报错）
# ------------------------------------------------------------------------------
DEVICE_NAME=$(yq -r ".global.device_name // \"\"" "$CONFIG_FILE")
[ -z "$DEVICE_NAME" ] || [ "$DEVICE_NAME" = "null" ] && DEVICE_NAME=$(hostname)

JITTER_MAX=$(yq -r ".global.jitter_max // 0" "$CONFIG_FILE")
GLOBAL_ROLLBACK=$(yq -r ".global.rollback_on_failure // true" "$CONFIG_FILE")

# 兼容新版 global.webhook.url 与旧版 global.webhook_url
WEBHOOK_URL=$(yq -r ".global.webhook.url // .global.webhook_url // \"\"" "$CONFIG_FILE")
WEBHOOK_LEVEL=$(yq -r ".global.webhook.notify_on // \"all\"" "$CONFIG_FILE")
WEBHOOK_HEADER=$(yq -r ".global.webhook.secret_header // \"\"" "$CONFIG_FILE")

NAME=$(yq -r ".tasks[$TASK_INDEX].name" "$CONFIG_FILE")
LOCAL_PATH=$(yq -r ".tasks[$TASK_INDEX].local_path" "$CONFIG_FILE")
PROVIDER_TYPE=$(yq -r ".tasks[$TASK_INDEX].provider.type" "$CONFIG_FILE")
VAL_FORMAT=$(yq -r ".tasks[$TASK_INDEX].validation.format // \"text\"" "$CONFIG_FILE")
VAL_MINSIZE=$(yq -r ".tasks[$TASK_INDEX].validation.min_size // 1" "$CONFIG_FILE")
ROLLBACK_ENABLED=$(yq -r ".tasks[$TASK_INDEX].rollback_on_failure // $GLOBAL_ROLLBACK" "$CONFIG_FILE")

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$DEVICE_NAME] [$NAME] $1"
}

# ------------------------------------------------------------------------------
# Webhook 统一发送函数
# 参数: $1=状态(success/error)  $2=消息内容  $3=文件哈希(可选)
# ------------------------------------------------------------------------------
send_webhook() {
    STATUS="$1"
    MSG="$2"
    HASH_SHORT="${3:-N/A}"
    NOW_TIME=$(date '+%Y-%m-%d %H:%M:%S')

    [ -z "$WEBHOOK_URL" ] || [ "$WEBHOOK_URL" = "null" ] && return 0
    if [ "$WEBHOOK_LEVEL" = "error_only" ] && [ "$STATUS" = "success" ]; then
        return 0
    fi

    FULL_TEXT="[${DEVICE_NAME}] 任务 [${NAME}] 状态: $(echo "$STATUS" | tr 'a-z' 'A-Z') - ${MSG} (Hash: ${HASH_SHORT})"

    # 使用 jq 安全构造 JSON，避免特殊字符引起格式错误
    PAYLOAD=$(jq -n \
        --arg dev "$DEVICE_NAME" \
        --arg task "$NAME" \
        --arg st "$STATUS" \
        --arg hash "$HASH_SHORT" \
        --arg tm "$NOW_TIME" \
        --arg txt "$FULL_TEXT" \
        '{
            device: $dev,
            task: $task,
            status: $st,
            sha256: $hash,
            time: $tm,
            text: $txt,
            msg_type: "text",
            content: { text: $txt }
        }')

    if [ -n "$WEBHOOK_HEADER" ] && [ "$WEBHOOK_HEADER" != "null" ]; then
        curl -s -X POST --connect-timeout 10 --max-time 15 \
            -H "Content-Type: application/json" \
            -H "$WEBHOOK_HEADER" \
            -d "$PAYLOAD" "$WEBHOOK_URL" >/dev/null 2>&1 || log "[WARN] Webhook 推送失败"
    else
        curl -s -X POST --connect-timeout 10 --max-time 15 \
            -H "Content-Type: application/json" \
            -d "$PAYLOAD" "$WEBHOOK_URL" >/dev/null 2>&1 || log "[WARN] Webhook 推送失败"
    fi
}

mkdir -p "$BACKUP_DIR" "$STATE_DIR"

# ------------------------------------------------------------------------------
# 步骤 1：随机延迟（避免多台服务器同时请求云端造成并发冲击）
# ------------------------------------------------------------------------------
if [ "${SKIP_JITTER:-0}" -ne 1 ] && [ "$JITTER_MAX" -gt 0 ]; then
    sleep $((RANDOM % JITTER_MAX + 1))
fi

LOCAL_DIR=$(dirname "$LOCAL_PATH")
BASE_NAME=$(basename "$LOCAL_PATH")
SAFE_NAME=$(echo "$NAME" | tr '/' '_')
mkdir -p "$LOCAL_DIR"

TMP_FILE="${LOCAL_PATH}.sync.tmp"
BAK_FILE="${BACKUP_DIR}/${SAFE_NAME}_${BASE_NAME}.bak"
ETAG_FILE="${STATE_DIR}/${SAFE_NAME}.etag"

# ------------------------------------------------------------------------------
# 步骤 2：组装 Curl 请求参数（支持 ETag 缓存协商与重试机制）
# ------------------------------------------------------------------------------
CURL_ARGS="-s --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 60 -w %{http_code} -o $TMP_FILE"

if [ -f "$ETAG_FILE" ] && [ -f "$LOCAL_PATH" ]; then
    CURL_ARGS="$CURL_ARGS --etag-compare $ETAG_FILE --etag-save $ETAG_FILE"
else
    CURL_ARGS="$CURL_ARGS --etag-save $ETAG_FILE"
fi

# ------------------------------------------------------------------------------
# 步骤 3：根据 4 种不同的存储模式发起数据拉取（向下兼容旧版别名）
# ------------------------------------------------------------------------------
case "$PROVIDER_TYPE" in
    "r2"|"r2_zerotrust")
        URL=$(yq -r ".tasks[$TASK_INDEX].provider.url" "$CONFIG_FILE")
        CF_ID=$(yq -r ".tasks[$TASK_INDEX].provider.cf_client_id" "$CONFIG_FILE")
        CF_SECRET=$(yq -r ".tasks[$TASK_INDEX].provider.cf_client_secret" "$CONFIG_FILE")
        HTTP_CODE=$(curl $CURL_ARGS \
            -H "CF-Access-Client-Id: ${CF_ID}" \
            -H "CF-Access-Client-Secret: ${CF_SECRET}" \
            "$URL")
        ;;

    "gist")
        GIST_ID=$(yq -r ".tasks[$TASK_INDEX].provider.gist_id" "$CONFIG_FILE")
        FILENAME=$(yq -r ".tasks[$TASK_INDEX].provider.filename" "$CONFIG_FILE")
        GH_TOKEN=$(yq -r ".tasks[$TASK_INDEX].provider.github_token" "$CONFIG_FILE")
        API_URL="https://api.github.com/gists/${GIST_ID}"
        
        GIST_TMP="${TMP_FILE}.gist_meta"
        HTTP_CODE=$(curl -s --retry 3 --connect-timeout 10 -w "%{http_code}" -o "$GIST_TMP" \
            $( [ -f "$ETAG_FILE" ] && [ -f "$LOCAL_PATH" ] && echo "--etag-compare $ETAG_FILE" ) \
            --etag-save "$ETAG_FILE" \
            -H "Authorization: Bearer ${GH_TOKEN}" \
            -H "Accept: application/vnd.github+json" \
            "$API_URL")
            
        if [ "$HTTP_CODE" -eq 200 ]; then
            IS_TRUNCATED=$(jq -r ".files[\"$FILENAME\"].truncated" "$GIST_TMP")
            if [ "$IS_TRUNCATED" = "false" ]; then
                jq -r ".files[\"$FILENAME\"].content" "$GIST_TMP" > "$TMP_FILE"
            elif [ "$IS_TRUNCATED" = "true" ]; then
                RAW_URL=$(jq -r ".files[\"$FILENAME\"].raw_url" "$GIST_TMP")
                curl -s -L --retry 3 -H "Authorization: Bearer ${GH_TOKEN}" -o "$TMP_FILE" "$RAW_URL"
            else
                log "[ERROR] Gist 远端找不到指定文件: $FILENAME"
                rm -f "$GIST_TMP" "$TMP_FILE" "$ETAG_FILE"
                send_webhook "error" "Gist 远端找不到指定文件: $FILENAME"
                exit 1
            fi
        fi
        rm -f "$GIST_TMP"
        ;;

    "webdav")
        URL=$(yq -r ".tasks[$TASK_INDEX].provider.url" "$CONFIG_FILE")
        USER=$(yq -r ".tasks[$TASK_INDEX].provider.username" "$CONFIG_FILE")
        PASS=$(yq -r ".tasks[$TASK_INDEX].provider.password" "$CONFIG_FILE")
        HTTP_CODE=$(curl $CURL_ARGS -L -u "${USER}:${PASS}" "$URL")
        ;;

    "url"|"http"|"https"|"direct")
        URL=$(yq -r ".tasks[$TASK_INDEX].provider.url" "$CONFIG_FILE")
        CUSTOM_HEADER=$(yq -r ".tasks[$TASK_INDEX].provider.custom_header // \"\"" "$CONFIG_FILE")
        if [ -n "$CUSTOM_HEADER" ] && [ "$CUSTOM_HEADER" != "null" ]; then
            HTTP_CODE=$(curl $CURL_ARGS -L -H "$CUSTOM_HEADER" "$URL")
        else
            HTTP_CODE=$(curl $CURL_ARGS -L "$URL")
        fi
        ;;

    *)
        log "[ERROR] 未知的存储端类型: $PROVIDER_TYPE (支持: r2, gist, webdav, url)"
        exit 1
        ;;
esac

# ------------------------------------------------------------------------------
# 步骤 4：校验 HTTP 响应状态码
# ------------------------------------------------------------------------------
if [ "$HTTP_CODE" -eq 304 ]; then
    rm -f "$TMP_FILE"
    exit 0
elif [ "$HTTP_CODE" -eq 302 ] || [ "$HTTP_CODE" -eq 401 ] || [ "$HTTP_CODE" -eq 403 ]; then
    log "[ERROR] 鉴权失败或被网关拦截 (HTTP $HTTP_CODE)，请检查凭据是否正确"
    rm -f "$TMP_FILE" "$ETAG_FILE"
    send_webhook "error" "云端鉴权失败或被拦截 (HTTP $HTTP_CODE)"
    exit 1
elif [ "$HTTP_CODE" -ne 200 ]; then
    log "[ERROR] 下载异常，HTTP 状态码: $HTTP_CODE"
    rm -f "$TMP_FILE"
    send_webhook "error" "文件下载异常 (HTTP $HTTP_CODE)"
    exit 1
fi

[ ! -f "$TMP_FILE" ] && exit 0

# ------------------------------------------------------------------------------
# 步骤 5：校验下载文件的完整性与格式规范
# ------------------------------------------------------------------------------
FILE_SIZE=$(wc -c < "$TMP_FILE" | tr -d ' ')
if [ "$FILE_SIZE" -lt "$VAL_MINSIZE" ]; then
    log "[ERROR] 文件体积 (${FILE_SIZE}B) 小于设定的最小阈值 (${VAL_MINSIZE}B)，放弃更新"
    rm -f "$TMP_FILE" "$ETAG_FILE"
    send_webhook "error" "下载文件体积过小 (${FILE_SIZE}B < ${VAL_MINSIZE}B)，疑似空文件或异常响应"
    exit 1
fi

# 通用文本清洗：剔除 Windows 回车符 (\r) 及不可见特殊空白字符（如 NBSP）
tr -d '\r' < "$TMP_FILE" | sed 's/\xC2\xA0/ /g' > "${TMP_FILE}.clean" && mv "${TMP_FILE}.clean" "$TMP_FILE"

if [ "$VAL_FORMAT" = "json" ]; then
    if ! jq empty "$TMP_FILE" >/dev/null 2>&1; then
        log "[ERROR] 文件未能通过 JSON 语法校验，放弃更新"
        rm -f "$TMP_FILE" "$ETAG_FILE"
        send_webhook "error" "远端文件未通过 JSON 语法校验，已放弃更新"
        exit 1
    fi
elif [ "$VAL_FORMAT" = "yaml" ]; then
    if ! yq e 'true' "$TMP_FILE" >/dev/null 2>&1; then
        log "[ERROR] 文件未能通过 YAML 语法校验，放弃更新"
        rm -f "$TMP_FILE" "$ETAG_FILE"
        send_webhook "error" "远端文件未通过 YAML 语法校验，已放弃更新"
        exit 1
    fi
elif [ "$VAL_FORMAT" = "toml" ]; then
    if ! yq e -p toml 'true' "$TMP_FILE" >/dev/null 2>&1; then
        log "[ERROR] 文件未能通过 TOML 语法校验，放弃更新"
        rm -f "$TMP_FILE" "$ETAG_FILE"
        send_webhook "error" "远端文件未通过 TOML 语法校验，已放弃更新"
        exit 1
    fi
fi

# ------------------------------------------------------------------------------
# 步骤 6：通过 SHA256 哈希精确比对内容是否有实质性变化
# ------------------------------------------------------------------------------
REMOTE_HASH=$(sha256sum "$TMP_FILE" | awk '{print $1}')
SHORT_HASH="${REMOTE_HASH:0:8}"
LOCAL_HASH=""
[ -f "$LOCAL_PATH" ] && LOCAL_HASH=$(sha256sum "$LOCAL_PATH" | awk '{print $1}')

if [ "$REMOTE_HASH" = "$LOCAL_HASH" ]; then
    rm -f "$TMP_FILE"
    exit 0
fi

log "[UPDATE] 检测到文件内容已变更 (SHA256: $SHORT_HASH)，开始更新"

# ------------------------------------------------------------------------------
# 步骤 7：备份原文件（覆盖旧备份）并执行文件同步更新替换
# ------------------------------------------------------------------------------
if [ -f "$LOCAL_PATH" ]; then
    cp -f "$LOCAL_PATH" "$BAK_FILE"
    log "[BACKUP] 原文件已备份至: $BAK_FILE"
fi

mv -f "$TMP_FILE" "$LOCAL_PATH"

# ------------------------------------------------------------------------------
# 步骤 8：依次执行 on_update 定义的后置动作钩子
# ------------------------------------------------------------------------------
ACTION_COUNT=$(yq ".tasks[$TASK_INDEX].on_update | length" "$CONFIG_FILE" 2>/dev/null || echo "0")
ROLLBACK_NEEDED=0
FAIL_REASON=""

if [ "$ACTION_COUNT" -gt 0 ]; then
    for a in $(seq 0 $((ACTION_COUNT - 1))); do
        ACTION=$(yq -r ".tasks[$TASK_INDEX].on_update[$a]" "$CONFIG_FILE")
        [ -z "$ACTION" ] || [ "$ACTION" = "null" ] && continue
        
        log "[ACTION] 执行后置动作: $ACTION"

        case "$ACTION" in
            restart_container:*)
                CONTAINER="${ACTION#restart_container:}"
                CODE=$(curl -s -o /dev/null -w "%{http_code}" --unix-socket /var/run/docker.sock \
                    -X POST "http://localhost/containers/${CONTAINER}/restart")
                sleep 3
                RUNNING=$(curl -s --unix-socket /var/run/docker.sock \
                    "http://localhost/containers/${CONTAINER}/json" | jq -r '.State.Running')
                if [ "$CODE" -ne 204 ] || [ "$RUNNING" != "true" ]; then
                    FAIL_REASON="容器 [$CONTAINER] 重启失败或启动后崩溃 (API状态码: $CODE, 运行状态: $RUNNING)"
                    log "[ERROR] $FAIL_REASON"
                    ROLLBACK_NEEDED=1
                    FAIL_CONTAINER="$CONTAINER"
                    break
                fi
                ;;

            signal_container:*)
                REST="${ACTION#signal_container:}"
                CONTAINER="${REST%%:*}"
                SIGNAL="${REST#*:}"
                CODE=$(curl -s -o /dev/null -w "%{http_code}" --unix-socket /var/run/docker.sock \
                    -X POST "http://localhost/containers/${CONTAINER}/kill?signal=${SIGNAL}")
                if [ "$CODE" -ne 204 ]; then
                    FAIL_REASON="向容器 [$CONTAINER] 发送信号 [$SIGNAL] 失败 (API状态码: $CODE)"
                    log "[ERROR] $FAIL_REASON"
                    ROLLBACK_NEEDED=1
                    break
                fi
                ;;

            *)
                if ! sh -c "$ACTION"; then
                    FAIL_REASON="自定义命令执行失败: $ACTION"
                    log "[ERROR] $FAIL_REASON"
                    ROLLBACK_NEEDED=1
                    break
                fi
                ;;
        esac
    done
fi

# ------------------------------------------------------------------------------
# 步骤 9：根据配置决定是否执行故障自动回滚机制与发送通知
# ------------------------------------------------------------------------------
if [ "$ROLLBACK_NEEDED" -eq 1 ]; then
    if [ "$ROLLBACK_ENABLED" = "true" ]; then
        log "[ROLLBACK] 异常回滚机制已启用，正在从备份还原旧文件..."
        if [ -f "$BAK_FILE" ]; then
            cp -f "$BAK_FILE" "$LOCAL_PATH"
            rm -f "$ETAG_FILE"
            if [ -n "$FAIL_CONTAINER" ]; then
                curl -s --unix-socket /var/run/docker.sock -X POST "http://localhost/containers/${FAIL_CONTAINER}/restart" >/dev/null
                log "[ROLLBACK] 已成功回滚配置文件并恢复容器 [$FAIL_CONTAINER] 运行"
            fi
            send_webhook "error" "${FAIL_REASON}，已自动回滚至上一版本配置" "$SHORT_HASH"
        else
            log "[WARN] 未找到对应的备份文件 $BAK_FILE，无法执行回滚"
            send_webhook "error" "${FAIL_REASON}，且未找到备份文件无法回滚" "$SHORT_HASH"
        fi
    else
        log "[WARN] 检测到异常，但当前已关闭自动回滚机制 (rollback_on_failure=false)，跳过回滚"
        send_webhook "error" "${FAIL_REASON} (未开启自动回滚)" "$SHORT_HASH"
    fi
    exit 1
fi

log "[SUCCESS] 任务 [$NAME] 的同步及后置操作全部完成"
send_webhook "success" "配置文件更新及后置操作全部完成" "$SHORT_HASH"
