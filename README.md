# Cloud Syncer 🚀

> 多节点配置文件云端自动化同步、热更新与故障自愈引擎
> 本仓库 Dockerfile、核心 Shell 脚本、CI/CD Workflow 均由 ChatGPT 辅助设计并编写完成。

---

## 🌟 仓库简介

在管理大量边缘节点或服务器集群时，逐个登录 SSH 修改配置文件极其繁琐。本项目旨在提供一个**极轻量、安全、通用**的 Sidecar（伴生）容器解决方案。

它能够定期从云端（支持 **Cloudflare R2**、**GitHub Gist**、**WebDAV** 或 **HTTP/HTTPS 直链**）拉取配置文件，自动进行内容清洗与多格式（JSON / YAML / TOML）语法校验。若检测到更新，则自动备份、无缝安全覆盖并触发后置动作（如重启指定容器或热重载），同时具备基础的**异常自动回滚保护**与 **Webhook 结构化通知**。

默认镜像地址：

* **GitHub Container Registry (GHCR):**
```bash
ghcr.io/castula/cloud-syncer:latest

```


* **DockerHub:**
```bash
spousal4806/cloud-syncer:latest

```



---

## ✨ 核心特点

* **极小体积**：基于轻量级 `Alpine Linux` 构建，内存与资源占用极低。
* **四大同步模式**：完美支持 `R2 (Zero Trust Access)`、`GitHub Gist`、`WebDAV` 以及 `HTTP/HTTPS 直链`。
* **智能防崩溃防护**：下载后自动清洗不可见字符（如 `\r` 及 NBSP 空白），并通过 `jq`/`yq` 严格校验语法，绝不写入错误配置。
* **无缝安全覆盖**：利用 Linux 同分区 `mv` 内核级原子操作，多进程读写永不出现残缺乱码。
* **服务自愈与回滚**：更新后若目标应用崩溃或执行异常，自动触发一键回滚并恢复旧版服务。
* **历史备份与定期清理**：自动将旧配置备份至 `/backups` 目录，支持自定义 Cron 定时清理。
* **结构化 Webhook 通知**：支持设备备注名（`device_name`），通知格式无缝兼容主流 IM 机器人（Telegram、飞书、钉钉、企业微信、Bark 等）。
* **向后兼容机制**：完美适配 `latest` 标签自动更新，老版本配置文件平滑升级。

---

## 🔧 快速启动 (Docker Compose)

推荐使用 Docker Compose 部署。容器首次启动若检测不到 `config.yaml`，会自动在挂载目录中生成一份带有详细注释的默认模板。

```yaml
services:
  cloud-syncer:
    image: spousal4806/cloud-syncer:latest
    container_name: cloud-syncer
    restart: unless-stopped
    volumes:
      - ./config:/app/config                         # 配置文件目录（首次启动会自动生成默认 config.yaml）
      - ./backups:/backups                           # 可选：将备份目录映射到宿主机
      - /path/to/app/data:/data                      # 挂载需要同步的目标应用数据目录
      - /var/run/docker.sock:/var/run/docker.sock:ro # 挂载 Docker 套接字，用于控制容器重启

```

---

## ⚙️ 配置文件说明 (`config.yaml`)

首次启动后，请修改 `./config/config.yaml`。支持同时配置多个不同模式的同步任务：

```yaml
global:
  device_name: "Node-HK-01"      # 设备备注名，将显示在日志与 Webhook 通知中
  jitter_max: 15                     # 随机延迟秒数（防多台服务器同时请求云端造成并发冲击）
  rollback_on_failure: true          # 是否开启异常自动回滚
  backup_clean_cron: "0 4 */3 * *"   # 定时清空 /backups 备份目录的 Cron 表达式
  webhook:
    url: "https://your-webhook-api.com"
    notify_on: "all"                 # "all" (全部通知) 或 "error_only" (仅报错/回滚时通知)

tasks:
  # [模式 1] Cloudflare R2 (通过 Zero Trust Access 服务令牌鉴权)
  - name: "app-config-r2"
    cron: "*/10 * * * *"
    local_path: "/data/config.json"
    rollback_on_failure: true
    provider:
      type: "r2"
      url: "https://r2.yourdomain.com/config.json"
      cf_client_id: "your-cf-access-client-id.access"
      cf_client_secret: "cfast_xxxxxxxxxxxxxxxxxxxx"
    validation:
      format: "json"                 # 可选: json / yaml / toml / text
      min_size: 50                   # 文件最小字节数限制，防空文件
    on_update:
      - "restart_container:my-app"   # 内置动作：重启指定容器并检查存活状态

  # [模式 2] GitHub Gist (通过 GitHub Personal Access Token 鉴权)
  - name: "app-config-gist"
    cron: "0 * * * *"                # Gist 建议设为每小时同步一次，避免高频请求触发 API 限制
    local_path: "/data/config.toml"
    rollback_on_failure: true
    provider:
      type: "gist"
      gist_id: "a1b2c3d4e5f6g7h8i9j0"
      filename: "config.toml"
      github_token: "ghp_xxxxxxxxxxxxxxxxxxxxxx"
    validation:
      format: "toml"
      min_size: 20
    on_update:
      - "restart_container:my-app"

  # [模式 3] WebDAV 网盘同步 (支持坚果云、Nextcloud、Alist 等)
  - name: "app-config-webdav"
    cron: "*/15 * * * *"
    local_path: "/data/settings.yaml"
    rollback_on_failure: true
    provider:
      type: "webdav"
      url: "https://dav.example.com/configs/settings.yaml"
      username: "admin"
      password: "your_password"
    validation:
      format: "yaml"
      min_size: 30
    on_update:
      - "signal_container:my-app:SIGHUP" # 内置动作：向容器发送信号实现零中断热重载

  # [模式 4] HTTP/HTTPS 直链下载 (支持公开直链或带自定义 Header 的私有直链)
  - name: "app-config-url"
    cron: "*/10 * * * *"
    local_path: "/data/rules.yaml"
    rollback_on_failure: true
    provider:
      type: "url"
      url: "https://example.com/public/rules.yaml"
      custom_header: ""              # 可选：如需鉴权可填写，例如 "Authorization: Bearer token123"
    validation:
      format: "yaml"
      min_size: 50
    on_update:
      - ""                           # 无需后置动作则留空或不写

```

---

## 🚀 GitHub Actions 手动构建

本项目采用纯手动触发构建机制：

1. 进入 GitHub 仓库的 **Actions** 页面。
2. 选择 **Manual Build and Push** 工作流。
3. 点击 **Run workflow** 按钮即可触发多架构（`amd64` / `arm64`）镜像的构建与推送。
4. 构建脚本会自动维护版本号（每次构建自动递增修订号，如 `v1.0.1` -> `v1.0.2`）并同步更新 GHCR 与 DockerHub。



---

## 🎉 感谢

* 项目架构设计、核心逻辑编写、自动化工作流配置：**Gemini 4 Argon**
