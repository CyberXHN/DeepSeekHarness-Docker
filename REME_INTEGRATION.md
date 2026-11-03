# ReMe 记忆系统接入调研（DSH × ReMe）

> 结论先行：**可行，架构上完全兼容本项目**。接入 = 新增一个 ReMe 服务容器（官方镜像，免构建）+ 在 dsh profile 安装官方插件 `@agentscope-ai/reme-dsh-plugin` + 配置 `endpoint`。改动集中在 `docker-compose.yml` 与 `entrypoint.sh`，不需要动 Dockerfile 的 dsh 安装本体。
>
> **实施状态（2026-11-03）**：QQBot 预设已落地——compose 新增 `reme` 服务，全部服务统一挂外部网络 `Bot`（弃用 baota_net）；entrypoint qqbot 分支首启自动装 reme 插件并追加 zh 配置 patch；endpoint 用容器名 `http://DeepSeekHarness-ReMe:2333`（qqbot 无状态页，无"两端可达"约束）。web profile 接入仍为草案（§4.2/§4.3 注）。

参考文档：[ReMe DSH 插件中文指南](https://github.com/agentscope-ai/ReMe/blob/main/integrations/dsh/README_ZH.md)（本地快照：`/tmp/reme_dsh_zh.md`，ReMe 仓库稀疏克隆：`/tmp/ReMe`）

---

## 1. 组件与数据流

接入涉及**两个独立组件**，别混淆：

| 组件 | 形态 | 作用 |
|---|---|---|
| **ReMe 服务** | Python HTTP 服务（`reme start`，默认 2333 端口），官方发布 Docker 镜像 | 记忆引擎本体：`search` / `auto_memory` / `auto_dream` 等 Job，记忆落盘为 workspace 里的 `daily/`、`digest/` Markdown 文件 |
| **reme-dsh-plugin** | npm 包（Node/cordis 插件），装进 dsh 的 profile | 桥接层：新会话注入"记忆使用指引"、注册只读工具 `reme_search`、捕获完成的对话批次提交 `auto_memory`、按 cron 调度 `auto_dream`、提供 Web 状态页 |

数据流：

```text
新会话 ──插件注入记忆使用指引（不塞原始记忆）──► Agent 判断需要历史 ──► reme_search ──► ReMe search ──► daily/digest
完成对话 ──插件按批次（默认每 5 回合）──► ReMe auto_memory ──► daily/ 日记
每日 23:00（插件 cron，Asia/Shanghai）──► ReMe auto_dream ──► digest/ 个人知识库
```

要点：
- 记忆的**事实源是 ReMe workspace 的 Markdown 文件**，索引/图谱均可重建；`reme_search` 由 Agent 按需调用，不自动污染上下文。
- 插件自身的提交队列（outbox）在 `$DSH_HOME/reme-memory/outbox`——位于我们已持久化的 `.dsh` 卷内，无需额外处理。

## 2. 版本兼容（已核实）

| 项 | 现状 | 兼容性 |
|---|---|---|
| 插件 peer 范围 | `dsh 0.1.7-rc.2 / 0.2.0-rc.2 / 0.2.1-alpha.2` 及兼容的 0.1.x / 0.2.x 正式版；**明确不含 0.3.x** | ✅ 镜像 `DSH_VERSION=latest` = `0.2.1-rc.5`，在范围内。⚠️ 若将来把 dsh 锁到 0.2.2-alpha.x 则不兼容 |
| 插件 npm 版本 | npm latest `0.1.2`（npmmirror 已同步）；GitHub main 已是 `0.1.3` | ✅ 可装；npmmirror 同步略有延迟，必要时去掉 registry 覆盖装最新 |
| ReMe 镜像 | `ghcr.io/agentscope-ai/reme`，`main` tag = main 分支 CI 产物，`latest` = 稳定 release（预发布不更新 latest）；**amd64 + arm64 双架构** | ✅ 与本项目双架构构建的发布习惯一致，免自行构建 |
| Node | 插件要求 `^22.19.0 || >=24.0.0` | ✅ 镜像是 node:24-trixie |

## 3. 关键部署事实（源码确认）

1. **endpoint 只有一个值，两端共用**：dsh 容器内的 Host（发起 `reme_search`/`auto_memory` 请求）和**浏览器**（ReMe 状态页直接 fetch ReMe 的 health/status/appConfig，见插件 `src/client/status-page.tsx` 的 `diagnosticClient()`）用同一个地址 → endpoint 必须选**浏览器和 dsh 容器都可达**的地址。这是本次接入最大的坑点。
2. **CORS 无需配置**：ReMe 服务端默认 `allow_origins=["*"]`（`reme/components/service/http_service.py`），跨源直连没问题。
3. **ReMe HTTP API 无认证**（含写/删操作），官方明确不建议暴露公网；端口只发布到 loopback / 内网网卡。
4. **容器入口**：镜像 entrypoint 是 `reme_container.py`，容器默认命令 `start`，可追加 kwargs 覆盖配置（如 `jobs.dream_cron.enabled=false`）；环境变量 `REME_HOST/REME_PORT/REME_WORKSPACE_DIR/REME_TIMEZONE` 自动映射。
5. **Dream 调度二选一**（官方建议）：ReMe 侧关闭 `dream_cron`，由插件按 `dreamCron`（默认 `0 23 * * *`，时区默认 `Asia/Shanghai`）调度。多个宿主共享 ReMe 时只允许一个调度方。
6. **ReMe 的 LLM 凭据**（`auto_memory`/`auto_dream` 必需，纯文件操作与 BM25 检索不需要）：
   - `LLM_API_KEY` / `LLM_BASE_URL` / `LLM_MODEL_NAME`（默认 `qwen3.7-plus` + dashscope）。
   - 用 DeepSeek 的话：`LLM_BASE_URL=https://api.deepseek.com/v1`、`LLM_MODEL_NAME=deepseek-chat`、`LLM_API_KEY` 复用 `.env` 的 `DEEPSEEK_API_KEY`。
   - **Embedding 语义检索默认关闭**：开箱只有 BM25/关键词检索；要语义检索需改 ReMe 配置启用 `as_embedding`/`embedding_store`（可后置做）。
7. **profile 归属**：`dsh web` ≡ `dsh --profile web`（`apps/cli/src/args.ts`），插件文档的 `dsh plugin --profile web add` 正好对应我们 entrypoint 的 web 模式；qqbot 是另一个 profile，插件可分别安装（`dsh plugin --profile qqbot add` 同样有效，只是没有状态页 UI）。

## 4. 接入方案（草案，未实施）

### 4.1 docker-compose.yml 新增 `reme` 服务（已实施；网络统一挂外部 `Bot`，不再用 baota_net）

```yaml
  reme:
    image: ghcr.io/agentscope-ai/reme:${REME_TAG:-latest}   # 生产建议锁版本/digest
    container_name: DeepSeekHarness-ReMe
    user: "1000:1000"
    # 记忆整理调度交给 dsh 插件（多宿主只允许一个调度方）
    command: ["start", "jobs.dream_cron.enabled=false"]
    environment:
      TZ: Asia/Shanghai
      REME_HOST: 0.0.0.0
      REME_PORT: "2333"
      REME_WORKSPACE_DIR: /data
      REME_TIMEZONE: Asia/Shanghai
      # auto_memory / auto_dream 必需；复用 DeepSeek key
      LLM_API_KEY: ${DEEPSEEK_API_KEY}
      LLM_BASE_URL: https://api.deepseek.com/v1
      LLM_MODEL_NAME: deepseek-chat
      # 可选：语义检索（默认关闭，需同时改 ReMe 配置）
      # EMBEDDING_API_KEY: ${EMBEDDING_API_KEY}
      # EMBEDDING_BASE_URL: https://dashscope.aliyuncs.com/compatible-mode/v1
    volumes:
      - ${APP_PATH:-./data}/reme:/data          # 记忆事实源，独立卷
    ports:
      - "${REME_BIND:-127.0.0.1}:2333:2333"     # 无认证服务，勿直接暴露公网
    restart: unless-stopped
    networks:
      - Bot          # 与 dsh 服务同网（外部网络，先 docker network create Bot）
```

### 4.2 dsh-web 服务追加（web 草案，未实施）

> qqbot 侧已实施：dsh-qqbot 容器直接注入 `REME_URL: http://DeepSeekHarness-ReMe:2333`（容器名直连，无浏览器约束，免 `host.docker.internal`/extra_hosts）。web 因状态页需浏览器可达 endpoint，选型仍按下表。

```yaml
    environment:
      # 插件 endpoint 的部署层默认值（< 插件配置 UI 手填 > 环境变量）
      REME_URL: ${REME_URL:-http://host.docker.internal:2333}
    extra_hosts:
      - "host.docker.internal:host-gateway"     # Linux 宿主必须；Docker Desktop 自带
```

**endpoint 选型**（两端可达原则）：

| 场景 | REME_URL / 插件 endpoint | ReMe 端口发布 |
|---|---|---|
| Windows/macOS Docker Desktop，本机浏览 | `http://host.docker.internal:2333`（容器和宿主浏览器都能解析） | `127.0.0.1:2333` |
| Linux 服务器（宝塔），本机或局域网浏览 | `http://<宿主内网IP>:2333` | `<内网IP>:2333`（或 0.0.0.0 + 防火墙限内网） |

不建议填容器名 `http://DeepSeekHarness-ReMe:2333`——dsh 容器可达但浏览器状态页不可达。

### 4.3 entrypoint.sh：qqbot 分支首启自动安装（已实施；web 分支为草案）

实现在 `entrypoint.sh` 的 qqbot 分支（腾讯插件安装块之后）：以 profile `package.json` 依赖为幂等标记；安装成功后向 profile 的 `cordis.patch.yml` 追加 `reme-memory` 配置条目（zh 指引）；安装失败仅告警不阻断 QQBot（修复后 `docker compose restart dsh-qqbot` 重试）。endpoint 不落文件，走 `REME_URL` 环境变量（compose 注入容器名直连地址）。

配置 patch 内容（追加到 `$DSH_HOME/profiles/qqbot/cordis.patch.yml`）：

```yaml
- id: reme-memory
  config:
    language: zh
```

> 源码依据：`dsh plugin add` = pnpm 装进 profile 目录 + `reconcile()` 把声明 `dsh.bundle` 的包自动追加进 profile `package.json` 的 `dsh.profile.bundles`，其自带 `cordis.patch.yml` 下次启动自动生效（`packages/boot/plugin-manager/src/operations.ts`）；补丁 override 按 `id` 深度优先定位（group 内嵌条目直接命中）、`config` 整体替换（`vendor/include/src/index.ts` 的 `applyEntryPatches`）。
> **不要**改用 `$DSH_HOME/cordis.patch.yml` home 层做 reme 配置：home 层压在 profile 层之上，会静默覆盖将来 Web UI 保存的同名配置（层序：bundle → profile patch → home patch → --patch）。
> web 分支（草案）：同款逻辑放 `web)` 分支、`--profile web`，但 web 是内置模板 profile（首启 `dsh web` 即生成 `profiles/web/`），只能以 package.json 依赖为标记，不能拿 `cordis.yml` 当标记。
> 插件安装走 npm，受 `NPM_CONFIG_REGISTRY` 影响：npmmirror 有 0.1.2，若要追 0.1.3 需临时用官方源。

### 4.4 QQBot 模式（已实施，本仓库默认形态）

- 无状态页 UI，但注入指引 / `reme_search` / 自动记忆 / Dream 调度全部可用（插件 `inject = ["agents","sessions","tools"]`，与 profile 无关；`agent/created` 注指引、`session/event` 捕获）。
- **会话粒度**（源码 `@tencent-connect/dsh-qqbot` `session-manager.ts`）：每个 QQ 对话方（c2c 用户 / 群）= 一个长生命周期会话（`qqbot:${appId}:${kind}:${peerId}`，idle 30 分钟驱逐后可 resume）→ 指引每会话注入一次并随历史长存（被压缩掉后自愈重注入），auto_memory 沿会话事件流每 5 回合成批。
- **Dream 调度方 = qqbot 插件**（`autoDreamEnabled` 默认 true，23:00 Asia/Shanghai）；ReMe 侧 `dream_cron` 已由 command 关闭。将来 web profile 若也装插件，web 侧 patch 需加 `autoDreamEnabled: false`，只留一个调度方。
- **记忆是共享池**：ReMe workspace 单用户假设，所有 QQ peer 共用一份记忆——A 的对话可被 B 检索到。对"bot 自己的记忆"人设合适；要 per-peer 隔离需多 ReMe 实例（官方未支持）。
- `reme_search` 无白名单障碍：qqbot 不做工具过滤，插件全局注册即可被 QQ 会话 Agent 调用。

## 5. 装完后的配置入口

> QQBot 形态无 Web UI：配置 = 直接编辑 `$DSH_HOME/profiles/qqbot/cordis.patch.yml` 的 `reme-memory` 条目（字段名与下表一致；endpoint 建议留空走 `REME_URL` 环境变量）。下表入口仅 web 形态可用。

Web UI → **插件 → ReMe 插件包 → reme-memory → 配置**（保存即原子更新，无需重启）：

| 配置键 | 默认 | 建议 |
|---|---|---|
| `endpoint` | `http://127.0.0.1:2333` | 改成 §4.2 选定的两端可达地址（REME_URL 已注入默认值） |
| `language` | `en` | `zh`（只影响之后新建的会话） |
| `autoMemoryEnabled` / `autoMemoryInterval` | `true` / `5` | 保持；想更实时可调小 |
| `autoDreamEnabled` / `dreamCron` / `timezone` | `true` / `0 23 * * *` / `Asia/Shanghai` | 保持（ReMe 侧 dream_cron 已关） |
| `rootAgentsOnly` | `true` | 保持（不给子 Agent 注入） |

验证入口：**Settings → ReMe Status** 六个标签（总览/自动记忆/记忆整理/组件/日记/个人知识库）；"打开 ReMe" 按钮直达 ReMe Studio（`http://<endpoint>/` 也能开）。

## 6. 安全要点

- ReMe HTTP **无认证**且有写/删操作 → 只发布 loopback/内网，公网部署必须加认证反代 + TLS。
- 记忆内容是对话摘要，落 `data/reme/`，属敏感数据，注意卷权限（容器以 UID 1000 运行，与本项目 rootless 约定一致）。
- ReMe 状态页在浏览器里直连 endpoint，`requestTimeoutMs` 默认 10s，跨公网链路慢时可调大。

## 7. 上线验证清单（QQBot 形态）

1. `docker logs DeepSeekHarness-ReMe` → 服务起在 `0.0.0.0:2333`；QQBot 容器内 `curl -s -X POST http://DeepSeekHarness-ReMe:2333/health_check` 正常返回（ReMe 接口皆为 POST job）。
2. dsh-qqbot 日志出现 `ReMe plugin installed.`；重启容器后 `dsh --profile qqbot` 正常启动（bundle patch 生效、`reme-memory` 条目加载无告警）。
3. QQ 私聊让 bot「用 reme_search 查长期记忆」→ 空库应答 `No relevant memory found.`（链路通）。
4. 聊 5+ 回合 → `data/reme/daily/` 落日记；到 23:00（或手动 `curl -X POST http://DeepSeekHarness-ReMe:2333/auto_dream`）后 `digest/` 出个人知识库。
5. 隔天再聊"还记得我昨天说的××吗" → 命中记忆。

（web 形态验证沿用：插件页出现 reme-memory → endpoint 保存 → ReMe Status 总览"已连接" → 新会话出现「上下文注入 · reme-memory」。）

## 8. 风险与开放问题

- ~~**profile package.json 检测点**~~（已源码核实解除）：`dsh plugin add` 经 pnpm 把包名写进 profile `package.json` 的 `dependencies`，`reconcile()` 再写 `dsh.profile.bundles`——grep 包名即可靠，entrypoint 已按此实现。
- **插件 0.1.3 尚未在 npmmirror 出现**：默认 registry 下装到 0.1.2，功能完整（本文档对应版本即 0.1.x）；追求最新可指定官方源安装。
- **dsh 升级到 0.2.2-alpha+ / 0.3.x 时插件 peer 会不匹配**：升级镜像前先看插件 peerDependencies 是否放行。
- **ReMe 镜像体积**（Python + torch 系依赖，`libgomp` 等）：首次拉取较大；内存上文件图谱/索引常驻，给 1g 左右 memory limit 起步。
- **语义检索**默认关：若 BM25 效果不够，第二阶段改 ReMe 配置启用 embedding（需另配 embedding 模型凭据，dashscope `text-embedding-v4` 或任意 OpenAI 兼容 embedding）。
- ~~qqbot profile 无 UI 的插件配置方式未实测~~（已源码核实）：字段名与 UI 键一致——Web UI 保存即写 profile patch 的 `reme-memory` 条目（官方 README），headless 手写同款条目即可（§4.3）。
