# DeepSeekHarness-Docker

[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（`dsh`）的 Docker 镜像项目：DeepSeek 官方开源的 AI Agent 框架（"Everything is a Plugin"，基于 Cordis）。

- 上游安装方式：官方 npm 包 [`@deepseek-ai/dsh`](https://www.npmjs.com/package/@deepseek-ai/dsh)（bin 命令 `dsh`），要求 Node ≥ 24.9
- 本镜像：`node:24-trixie`（Debian 13 标准版 + 官方 Node 24）+ rootless npm 全局安装 + 出厂备份自解压（复刻自本目录 OpenClaw-Docker 的模式）
- 构建方式：GitHub Actions 手动触发，构建产物（镜像 tar）上传到工作流 Artifacts，不推送镜像仓库

## 文件说明

| 文件 | 作用 |
|---|---|
| `Dockerfile` | 镜像定义：Debian 13 标准版基座、基础工具链、npm local prefix 安装 dsh、打包出厂备份 |
| `entrypoint.sh` | 首启自解压初始化 + 动态绑定容器 IP 启动 `dsh web` |
| `docker-compose.yml` | 本地运行：端口映射 + 4 个数据卷 |
| `.github/workflows/Build_DeepSeekHarness_AMD64_Docker_Image.yml` | AMD64 构建 |
| `.github/workflows/Build_DeepSeekHarness_ARM64_Docker_Image.yml` | ARM64 构建（`ubuntu-24.04-arm` 原生跑） |

## GitHub Actions 构建

两个 workflow 均为 `workflow_dispatch` 手动触发，输入参数：

- `image_tag`：镜像标签，默认 `latest`
- `dsh_version`：`@deepseek-ai/dsh` 的 npm 版本，默认 `latest`（可锁定如 `0.2.1-rc.5`）

构建完成后镜像 tar 上传到工作流 Artifacts（保留 30 天），并自动执行验证（`dsh --version`、出厂备份、目录权限）和 Web 启动冒烟测试。下载后 `docker load -i <tar>` 导入。

## 运行

```sh
# docker run
docker run -d --name dsh -p 3080:3080 \
  -v ./data/npm-global:/home/node/.npm-global \
  -v ./data/dsh:/home/node/.dsh \
  -v ./data/agents:/home/node/.agents \
  -v ./data/workspace:/home/node/workspace \
  deepseek-harness:latest

# 或 docker compose（默认 = QQBot 模式，rootless；Web 用 --profile web）
docker compose up -d
docker compose --profile web up -d
```

> **首启解包提示**：volume 为空的首次启动会从镜像内置备份解包 102MB（数万个小文件），日志停在 `initializing from image backup...` 数分钟属正常。Docker Desktop（Windows/macOS）的 bind mount 跨 VM 文件系统较慢，生产服务器（named volume / Linux bind mount）约 1-2 分钟；解包完成后日志会出现 `dsh version: x.y.z` 行。

### 首次访问

1. `docker logs -f dsh` 查看 dsh 打印的 URL，**其中带启动 token**（即登录凭证）：
   `http://172.17.0.2:3080/?token=...`
2. 把 URL 里的容器 IP 换成你访问容器用的地址，例如 `http://localhost:3080/?token=...`，浏览器打开即进入 Web UI。

### 访问地址与信任围栏（重要）

`dsh web` 有浏览器信任围栏（Host 校验）：**loopback 地址（localhost / 127.0.0.1）默认放行**；用局域网 IP 或域名访问时，API 会返回 403，需要追加信任的主机：

```sh
# docker run 场景
docker run -d -p 3080:3080 -e DSH_WEB_EXTRA_ARGS="--trusted-host 192.168.1.10:3080" deepseek-harness:latest

# compose 场景：取消 environment 中 DSH_WEB_EXTRA_ARGS 的注释
```

上游设计为"Web UI 只监听 loopback + 前置反代"，并明确拒绝绑定 `0.0.0.0` 通配地址；本镜像按上游文档推荐的容器姿势，由 entrypoint 动态绑定容器自身 IP（`hostname -i`），端口映射即可直通，无需容器内反代。**启动 URL 即凭证，3080 端口不要直接暴露公网**；公网部署请按上游文档加反代 + TLS（`--public-url` / `--tls-cert`，可用 `DSH_WEB_EXTRA_ARGS` 传入）。

## 不重建镜像升级 dsh（自解压模式）

镜像内 npm 全局目录备份为 `/opt/dsh-backup.tar.xz`：volume 为空时首启自动解包初始化，之后安装位于数据卷 `npm-global` 中，升级不再依赖重建镜像：

```sh
docker exec dsh npm install -g @deepseek-ai/dsh@latest
docker restart dsh
```

## 数据卷

| 容器路径 | 内容 |
|---|---|
| `/home/node/.npm-global` | npm 全局目录（含 dsh 安装本体，升级持久化） |
| `/home/node/.dsh` | harness 主目录：profiles、插件、会话、设置（`$DSH_HOME`） |
| `/home/node/.agents` | 共享 agent 配置根：用户全局 `AGENTS.md`、`skills/`（`$DSH_AGENTS_HOME`） |
| `/home/node/workspace` | agent 工作区（容器工作目录） |

## QQBot 模式（腾讯官方插件）

不想用 Web UI、只想把 dsh 当 QQ 机器人 Assistant 用：腾讯 `tencent-connect` 官方为 dsh 出了第一方插件 [`@tencent-connect/dsh-qqbot`](https://github.com/tencent-connect/dsh-qqbot)（[npm](https://www.npmjs.com/package/@tencent-connect/dsh-qqbot)）。架构为 QQ 用户 → QQ WebSocket（出站长连接）→ 插件 → dsh agent loop → LLM，**不需要 Web UI，也不需要公网入站端口**。

```sh
# .env 里配 QQBOT_APPID / QQBOT_SECRET（免扫码绑定）
docker compose up -d
```

`qqbot` 不是 dsh 内置模板 profile：首次启动时 entrypoint 检测到 profile 不存在会**自动安装**官方插件（日志出现 `installing @tencent-connect/dsh-qqbot` / `Plugin installed.`，需 1-2 分钟），之后随 `.dsh` 卷持久化。手动安装或锁版本的等价命令：

```sh
docker compose run --rm dsh-qqbot dsh plugin --profile qqbot add @tencent-connect/dsh-qqbot
```

不用 compose 时等价的 docker run：

```sh
docker run -d --name dsh-qqbot \
  -e QQBOT_APPID=你的AppID -e QQBOT_SECRET=你的AppSecret \
  -v ./data/npm-global:/home/node/.npm-global \
  -v ./data/dsh:/home/node/.dsh \
  -v ./data/agents:/home/node/.agents \
  -v ./data/workspace:/home/node/workspace \
  deepseek-harness:latest dsh --profile qqbot
```

不设 `QQBOT_APPID`/`QQBOT_SECRET` 时，首次启动会在终端出二维码，手机 QQ 扫码绑定后凭据自动存入 profile。常用配置（[完整列表](https://github.com/tencent-connect/dsh-qqbot#配置项)）：`requireMention`（群聊是否需 @bot）、`access.c2cMode`/`access.groupMode`（私聊/群聊白名单）、`provider`/`model`（默认 `deepseek-official` + `deepseek-chat`）。群聊支持 `@bot` 触发、白名单、内置 `/new` `/model` `/stop` 等斜杠命令。

**模型凭据（DeepSeek 官网 API Key）**：`.env` 里配 `DEEPSEEK_API_KEY=sk-xxx` 经 compose 注入即可——这是官方支持的环境变量回退（内置 provider 配置 `apiKeyEnv: DEEPSEEK_API_KEY`，按请求解析）。解析优先级：Web UI「Settings → Models」存入 `$DSH_HOME/.credentials.yaml` 的凭据 **>** `DEEPSEEK_API_KEY` 环境变量。容器内无凭据时报 `MISSING_CREDENTIAL`。安全权衡：环境变量方式下 key 会出现在 `docker inspect` 输出里；更稳妥的是进一次 Web UI 把 key 存进凭据文件（随 `.dsh` 卷持久化，不进进程环境），compose 的注入留作 QQBot 无头场景的便利通道。

compose 已内置 `dsh-qqbot` 服务（rootless `user: 1000:1000`、cpuset/内存限制、npmmirror 插件源，对齐 OpenClaw 的运行姿势），详见 [docker-compose.yml](docker-compose.yml) 顶部注释。

## 用非 web 模式

`CMD ["web"]` 只是默认入口，entrypoint 会原样透传其他命令：

```sh
docker run --rm deepseek-harness:latest dsh headless "总结这个仓库"
docker run --rm -it deepseek-harness:latest dsh tui
docker run --rm deepseek-harness:latest dsh --version
```

## 本地构建

```sh
docker build -t deepseek-harness:local --build-arg DSH_VERSION=latest .
```
