#!/bin/sh
set -e

# ==============================================================================
# 服务入口与定时调度初始化脚本
# 功能：
#   1. 检测 /app/config/config.yaml 是否存在，若不存在则自动从模板复制生成
#   2. 检查老版本配置文件兼容性并输出升级提示
#   3. 根据配置动态注册同步任务和备份清理任务到系统 Cron
#   4. 启动 crond 守护进程
# ==============================================================================

CONFIG_DIR=$(dirname "$CONFIG_FILE")
mkdir -p "$CONFIG_DIR" /backups /tmp/syncer_state

echo "=================================================="
echo "          Cloud File Syncer - Starting          "
echo "=================================================="

# 1. 若检测不到配置文件，自动生成带有友好注释的默认配置
if [ ! -f "$CONFIG_FILE" ]; then
    echo "[INIT] 未检测到配置文件，正在生成默认配置模板: $CONFIG_FILE"
    cp -f /app/config.example.yaml "$CONFIG_FILE"
    echo "[INIT] 模板已生成，请编辑宿主机对应的 config.yaml 配置同步任务后重启容器。"
fi

# 2. 老版本配置向后兼容性检查 (帮助使用 latest 镜像自动更新的老用户平滑过渡)
if ! yq e '.global.device_name' "$CONFIG_FILE" >/dev/null 2>&1 || [ "$(yq -r '.global.device_name' "$CONFIG_FILE")" = "null" ]; then
    echo "[NOTICE] 检测到旧版或精简版 config.yaml，缺少 global.device_name 字段，将默认使用容器主机名: $(hostname)"
fi

> /etc/crontabs/root

# 3. 检查是否开启了异常回滚机制（全局开启 或 任意子任务开启）
GLOBAL_ROLLBACK=$(yq -r '.global.rollback_on_failure // true' "$CONFIG_FILE")
ANY_TASK_ROLLBACK=$(yq -r '.tasks[]?.rollback_on_failure // false' "$CONFIG_FILE" 2>/dev/null | grep -q "true" && echo "true" || echo "false")
CLEAN_CRON=$(yq -r '.global.backup_clean_cron // ""' "$CONFIG_FILE")

if [ "$GLOBAL_ROLLBACK" = "true" ] || [ "$ANY_TASK_ROLLBACK" = "true" ]; then
    if [ -n "$CLEAN_CRON" ] && [ "$CLEAN_CRON" != "null" ]; then
        echo "[INIT] 异常回滚机制已启用，注册备份清理任务 -> 周期: ($CLEAN_CRON)"
        echo "$CLEAN_CRON rm -rf /backups/* && echo \"[\$(date '+%Y-%m-%d %H:%M:%S')] [CLEANUP] 已按计划清空 /backups 备份目录\" >> /proc/1/fd/1 2>> /proc/1/fd/2" >> /etc/crontabs/root
    fi
fi

# 4. 读取并注册同步任务
TASK_COUNT=$(yq '.tasks | length' "$CONFIG_FILE" 2>/dev/null || echo "0")

if [ "$TASK_COUNT" -eq 0 ]; then
    echo "[WARN] 当前配置文件中未启用任何同步任务 (tasks 列表为空)。"
    echo "[INFO] 容器将保持后台挂起状态，修改 config.yaml 后请重启容器生效。"
    exec tail -f /dev/null
fi

for i in $(seq 0 $((TASK_COUNT - 1))); do
    NAME=$(yq -r ".tasks[$i].name" "$CONFIG_FILE")
    CRON=$(yq -r ".tasks[$i].cron" "$CONFIG_FILE")
    echo "[INIT] 注册同步任务 [$NAME] -> 周期: ($CRON)"
    
    # 使用 flock 防止同一任务重复并发执行
    SAFE_LOCK_NAME=$(echo "$NAME" | tr '/' '_')
    echo "$CRON flock -n /tmp/syncer_state/${SAFE_LOCK_NAME}.lock /app/sync_task.sh $i >> /proc/1/fd/1 2>> /proc/1/fd/2" >> /etc/crontabs/root
    
    # 容器启动时，立即顺次执行一次初同步（跳过随机延迟）
    SKIP_JITTER=1 /app/sync_task.sh "$i" || true
done

echo "[INFO] 所有任务初始化完成，定时服务 crond 已启动。"
exec crond -f -l 8
