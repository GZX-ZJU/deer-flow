# DeerFlow 项目架构说明

本文基于当前仓库代码结构整理，目标不是重复 README，而是解释这个项目在代码层面是如何组织、启动、通信和扩展的。

## 1. 项目定位

DeerFlow 2.0 不是一个单纯的聊天应用，而是一个“Super Agent Harness”。它把下面几类能力组合成一个完整系统：

- Web 前端：提供工作区、聊天、产物查看、技能/模型/Agent 管理等 UI。
- LangGraph Agent Runtime：真正执行 LLM 推理、工具调用、子 Agent 调度、记忆注入、Sandbox 执行。
- Gateway API：补齐 LangGraph 不适合承载的 REST 能力，比如模型列表、技能管理、文件上传、产物读取、线程本地数据清理、自定义 Agent CRUD。
- Sandbox / 文件系统：为每个 thread 提供独立的工作目录、上传目录、输出目录。
- Skills / MCP / Community Tools：为 Agent 注入工作流说明和外部工具。
- Memory / Custom Agents / IM Channels：把 DeerFlow 从单一聊天工具扩展成可配置、可长期使用、可接入多渠道的 agent 平台。

它的架构核心思想可以概括成一句话：

> 前端负责交互，Gateway 负责外围资源管理，LangGraph 负责 Agent 运行时，所有线程数据落在统一的线程目录和配置体系上。

## 2. 顶层架构

### 2.1 运行时拓扑

在本地开发和 Docker 模式下，系统都是类似的四层结构：

```text
Browser
  |
  v
Nginx (:2026)
  |-- /api/langgraph/*  -> LangGraph Server (:2024)
  |-- /api/*            -> Gateway API (:8001)
  `-- /*                -> Next.js Frontend (:3000)
```

职责边界很明确：

- `Nginx` 是统一入口，负责反向代理、CORS、SSE/长连接转发。
- `Frontend` 只做界面和状态管理，不直接承载 Agent 逻辑。
- `LangGraph Server` 是真正的 agent runtime。
- `Gateway API` 是一个配套服务，管理文件、配置、扩展和本地持久化资源。

### 2.2 代码入口

主要入口文件如下：

- 根目录启动编排：`Makefile`、`scripts/serve.sh`
- LangGraph 图配置：`backend/langgraph.json`
- Gateway 入口：`backend/app/gateway/app.py`
- Agent 构造入口：`backend/packages/harness/deerflow/agents/lead_agent/agent.py`
- 前端 App Router 入口：`frontend/src/app/layout.tsx`、`frontend/src/app/workspace/layout.tsx`

其中 `scripts/serve.sh` 会按顺序启动：

1. LangGraph server
2. Gateway API
3. Frontend
4. Nginx

所以从开发者体验上看，`make dev` 是一键启动整套系统；但从代码结构上看，这是 3 个服务 + 1 个代理层，而不是单体应用。

## 3. 仓库分层

仓库大致分为四块：

```text
deer-flow/
├── frontend/               # Next.js 前端
├── backend/                # Python 后端
│   ├── app/gateway/        # FastAPI Gateway
│   └── packages/harness/   # DeerFlow 核心运行时
├── skills/                 # 公共/自定义技能
├── docker/                 # Nginx、compose、provisioner
└── scripts/                # 本地开发与部署脚本
```

这里最容易误判的一点是：

- `backend/app/gateway` 不是后端核心逻辑的全部，只是 Gateway。
- 真正的 agent、tool、sandbox、memory、subagent、model factory、skills loader 都在 `backend/packages/harness/deerflow/` 下。

也就是说，Python 部分内部本身又分成两层：

- `app/gateway/`：面向 HTTP 的应用层
- `packages/harness/deerflow/`：面向 agent runtime 的核心库层

## 4. 一次聊天请求是怎么走的

### 4.1 前端发起

聊天主页面在：

- `frontend/src/app/workspace/chats/[thread_id]/page.tsx`

这个页面组合了：

- `MessageList`：消息展示
- `InputBox`：输入与上传
- `TodoList`：plan mode 的任务清单展示
- `ArtifactTrigger` / `ChatBox`：产物侧栏
- `TokenUsageIndicator`：token 使用展示

线程交互的核心 Hook 是：

- `frontend/src/core/threads/hooks.ts`

它使用 `@langchain/langgraph-sdk/react` 的 `useStream()` 直接连到 LangGraph API，而不是经由 Gateway 中转。这一点非常关键：

- 聊天流式消息：前端 -> LangGraph
- 配置/文件/技能/产物等 REST 资源：前端 -> Gateway

### 4.2 前端连接哪两个后端

前端的 URL 解析在：

- `frontend/src/core/config/index.ts`
- `frontend/src/core/api/api-client.ts`

规则是：

- LangGraph 默认走当前站点下的 `/api/langgraph`
- Gateway 默认走当前站点同源的 `/api`
- 如果配置了 `NEXT_PUBLIC_BACKEND_BASE_URL` 或 `NEXT_PUBLIC_LANGGRAPH_BASE_URL`，则可改为直连

所以 Nginx 的作用不只是“统一端口”，而是把前端对两个后端的访问整合成一个同源站点，减少 CORS 和部署复杂度。

### 4.3 LangGraph 侧处理

LangGraph 入口定义在 `backend/langgraph.json`：

- 图名：`lead_agent`
- 构造函数：`deerflow.agents:make_lead_agent`
- checkpointer：`agents/checkpointer/async_provider.py`

`make_lead_agent()` 做了几件事：

1. 解析本次运行模型
2. 构建 middleware 链
3. 装配可用 tools
4. 构建系统提示词
5. 用 `langchain.agents.create_agent()` 生成可执行 agent

Agent 使用的状态模型是 `ThreadState`，在：

- `backend/packages/harness/deerflow/agents/thread_state.py`

它在 LangGraph 的基础 `AgentState` 上增加了 DeerFlow 特有状态：

- `sandbox`
- `thread_data`
- `title`
- `artifacts`
- `todos`
- `uploaded_files`
- `viewed_images`

这说明 DeerFlow 不是把所有状态都塞进 message history，而是显式维护一套线程级状态。

### 4.4 结果回到前端

前端 `useThreadStream()` 会接收：

- messages
- state updates
- 自定义事件
- tool end 事件

其中有几个特别重要的 UI 对接：

- title 更新后会回写 React Query 缓存，刷新线程列表标题
- `task_running` 自定义事件会更新 subtask 卡片
- `artifacts` 和 `todos` 从 thread state 直接驱动 UI

因此前端并不只是“渲染文本聊天”，而是在消费 DeerFlow 的结构化 thread state。

## 5. 后端核心：Lead Agent Runtime

### 5.1 Middleware 链

Lead agent 的 middleware 主要由两部分组成：

- 通用运行时 middleware：`tool_error_handling_middleware.py`
- lead agent 专属 middleware：`lead_agent/agent.py`

大致执行顺序是：

1. `ThreadDataMiddleware`
2. `UploadsMiddleware`
3. `SandboxMiddleware`
4. `DanglingToolCallMiddleware`
5. `GuardrailMiddleware`（如果配置）
6. `ToolErrorHandlingMiddleware`
7. `SummarizationMiddleware`（如果启用）
8. `TodoMiddleware`（plan mode）
9. `TitleMiddleware`
10. `MemoryMiddleware`
11. `ViewImageMiddleware`（模型支持 vision 时）
12. `DeferredToolFilterMiddleware`（tool search 打开时）
13. `SubagentLimitMiddleware`（启用 subagent 时）
14. `LoopDetectionMiddleware`
15. `ClarificationMiddleware`

这条链说明 DeerFlow 的设计风格是“把横切能力尽量 middleware 化”，而不是把所有逻辑塞进主 agent prompt。

### 5.2 这些 middleware 各自解决什么问题

可以把它们理解为几类：

- 线程资源准备：`ThreadDataMiddleware`、`SandboxMiddleware`
- 输入补强：`UploadsMiddleware`、`ViewImageMiddleware`
- 安全和稳定性：`GuardrailMiddleware`、`ToolErrorHandlingMiddleware`、`LoopDetectionMiddleware`
- 运行体验：`TitleMiddleware`、`TodoMiddleware`
- 上下文治理：`SummarizationMiddleware`、`MemoryMiddleware`
- 流程控制：`ClarificationMiddleware`

这也是 DeerFlow 与很多“直接把 tool 绑给模型”的项目最大的区别：它做了比较重的运行时治理。

### 5.3 Prompt 体系

Lead agent prompt 在：

- `backend/packages/harness/deerflow/agents/lead_agent/prompt.py`

组成部分包括：

- 角色定义
- Agent soul
- Memory 注入
- 思考风格约束
- clarification 规则
- skills 注入
- deferred tools 说明
- subagent 说明
- 工作目录说明
- 输出风格要求

这意味着 DeerFlow 的 prompt 不是单文件静态字符串，而是“多个动态片段拼接”的结果。拼接内容会受以下因素影响：

- 当前 agent 名称
- 是否启用 subagent
- 当前模型是否支持视觉
- 已启用 skills
- 记忆内容
- 当前线程目录约束

## 6. Tool 系统

### 6.1 工具来源

DeerFlow 的工具不是单一来源，而是三层叠加：

1. `config.yaml` 中声明的常规 tools
2. 内建 tools
3. MCP tools

工具装配入口在：

- `backend/packages/harness/deerflow/tools/tools.py`

其中内建工具包括：

- `present_file`
- `ask_clarification`
- `view_image`（按模型能力条件注入）
- `task`（按 subagent 开关条件注入）

### 6.2 MCP 工具

MCP 装配在：

- `backend/packages/harness/deerflow/mcp/tools.py`

它会：

1. 读取 `extensions_config.json`
2. 构造启用的 MCP server 配置
3. 处理 HTTP/SSE 类型 MCP 的 OAuth 头注入
4. 通过 `langchain-mcp-adapters` 拉取 tools

和常规配置不同，MCP 和 skill 的“启用状态”都不放在 `config.yaml`，而是单独放在 `extensions_config.json`。这样前端可以通过 Gateway 动态开关，而不必修改主配置文件。

### 6.3 Tool Search / Deferred Loading

如果 `tool_search` 打开，MCP tools 不会全部直接暴露给模型，而是先放进 deferred registry，再通过 `tool_search` 做选择性暴露。

这个设计反映出 DeerFlow 一个很实际的优化方向：

- 工具越多，模型 tool schema 越臃肿
- 因此需要一种延迟暴露机制控制 prompt/token 膨胀

## 7. Sandbox 与线程文件系统

### 7.1 线程目录结构

线程文件系统由 `deerflow.config.paths.Paths` 统一管理，目录结构大致是：

```text
{DEER_FLOW_HOME or backend/.deer-flow}/
├── memory.json
├── USER.md
├── agents/
│   └── {agent_name}/
│       ├── config.yaml
│       ├── SOUL.md
│       └── memory.json
└── threads/
    └── {thread_id}/
        └── user-data/
            ├── workspace/
            ├── uploads/
            └── outputs/
```

Agent 视角看到的是虚拟路径：

- `/mnt/user-data/workspace`
- `/mnt/user-data/uploads`
- `/mnt/user-data/outputs`

Skills 目录会映射到：

- `/mnt/skills`

这层映射由 `Paths.resolve_virtual_path()` 和 sandbox provider 协同完成。

### 7.2 Sandbox provider

Sandbox 抽象在：

- `backend/packages/harness/deerflow/sandbox/`

当前主要有两类 provider：

- `LocalSandboxProvider`：本地文件系统/本地执行
- `AioSandboxProvider`：容器或远端沙箱

从代码组织上看，sandbox 相关又分三层：

- 抽象接口：provider / sandbox
- 本地实现：`sandbox/local/`
- 社区或容器实现：`community/aio_sandbox/`

### 7.3 为什么 Gateway 也会接触 Sandbox

虽然 LangGraph 才是 agent runtime，但上传接口在 Gateway。用户上传文件后，Gateway 会：

1. 把原文件写入 thread 的 `uploads/`
2. 对 PDF/PPT/Excel/Word 尝试转 Markdown
3. 如果当前不是 local sandbox，还会同步到 sandbox 内对应虚拟路径

相关代码在：

- `backend/app/gateway/routers/uploads.py`

所以“线程文件目录”是前后端、Gateway、LangGraph、Sandbox 共用的交汇点。

## 8. 文件上传、产物与线程生命周期

### 8.1 上传

上传 API：

- `POST /api/threads/{thread_id}/uploads`
- `GET /api/threads/{thread_id}/uploads/list`
- `DELETE /api/threads/{thread_id}/uploads/{filename}`

上传后的文件会生成：

- 真实 host 路径
- sandbox 虚拟路径
- artifact URL

这使前端既能把文件交给 agent 使用，也能直接从产物接口查看。

### 8.2 产物读取

产物接口在：

- `backend/app/gateway/routers/artifacts.py`

它支持：

- 读取 thread 内文件
- 自动识别 HTML / text / binary
- `download=true` 强制下载
- 读取 `.skill` ZIP 包内部文件

前端产物面板的实现核心在：

- `frontend/src/components/workspace/chats/chat-box.tsx`
- `frontend/src/core/artifacts/hooks.ts`

也就是说，产物不是“聊天消息附件”，而是一个独立的线程文件视图。

### 8.3 线程删除

线程删除被拆成两段：

1. LangGraph 删除 thread state
2. Gateway 删除 DeerFlow 本地 thread 目录

Gateway 这一段在：

- `backend/app/gateway/routers/threads.py`

这是一个很明确的边界设计：

- LangGraph 负责图状态
- DeerFlow 自己负责本地文件生命周期

## 9. Model 系统

模型工厂在：

- `backend/packages/harness/deerflow/models/factory.py`

主配置来自：

- `config.yaml`

每个模型条目至少包含：

- `name`
- `display_name`
- `use`
- `model`
- 各种 provider 参数

工厂流程大致是：

1. 读取 `AppConfig`
2. 根据 `use` 反射出模型类
3. 合并 thinking / reasoning_effort / provider 特定参数
4. 实例化 LangChain `BaseChatModel`
5. 按需附加 tracing

几个实现上的重点：

- DeerFlow 支持“逻辑模型名”和“真实 provider model id”分离
- 是否支持 thinking / reasoning effort / vision 是显式配置出来的
- Codex/Claude 这类 CLI-backed provider 有单独适配层
- 前端模型列表只经 Gateway 暴露安全字段，不暴露 API Key

## 10. Memory 系统

Memory 相关代码在：

- `backend/packages/harness/deerflow/agents/memory/`

它由两部分组成：

- `MemoryMiddleware`：在运行时把 memory 摘要注入 prompt，并在对话后触发更新
- `updater.py`：负责内存文件读写、缓存、去噪、LLM 驱动更新

全局 memory 默认落在：

- `{base_dir}/memory.json`

自定义 agent 还有独立 memory：

- `{base_dir}/agents/{agent_name}/memory.json`

当前 memory 的数据结构大致包含：

- user work/personal/top-of-mind
- history recent/earlier/long-term
- facts 列表

这里的设计特点是：

- memory 不是数据库，而是 JSON 文件
- 通过 mtime + 内存缓存减轻重复读取
- 明确过滤上传文件事件，避免把临时上传行为写进长期记忆

这套设计更偏“轻量可本地运行”，而不是重型服务化存储。

## 11. Skills 系统

### 11.1 技能目录与发现

Skills loader 在：

- `backend/packages/harness/deerflow/skills/loader.py`

默认扫描：

- `skills/public/**/SKILL.md`
- `skills/custom/**/SKILL.md`

loader 会递归发现技能，并结合 `extensions_config.json` 判断 enabled 状态。

### 11.2 Skills 在运行时的作用

Skills 并不是 Python plugin，而主要是“提示词工作流资产”：

- 提供特定任务的操作规程
- 被注入 system prompt
- 可以被前端开启/关闭
- 也支持从 `.skill` 包安装

安装和状态管理在 Gateway：

- `backend/app/gateway/routers/skills.py`

前端对应 API 在：

- `frontend/src/core/skills/api.ts`

所以 Skills 的整体链路是：

`skills/` 目录 -> loader -> Gateway 列表/开关/安装 -> lead prompt 注入

## 12. Subagent 系统

Subagent 相关代码在：

- `backend/packages/harness/deerflow/subagents/`
- `backend/packages/harness/deerflow/tools/builtins/task_tool.py`

执行核心是：

- `subagents/executor.py`

基本机制是：

1. 主 agent 调用 `task` tool
2. 后端创建 `SubagentExecutor`
3. 按配置筛选子 agent 可用工具
4. 在后台线程池中执行子 agent
5. 把中间 AI message 和最终结果回传给主线程

它不是“另起一个服务”，而是在同一个后端 runtime 中复用模型工厂、middleware 体系和部分 thread 状态。

几个关键约束：

- 并发数有限制
- 子 agent 工具可白名单/黑名单筛选
- 子 agent 可以继承父级模型，或单独指定模型
- 前端会把 subtask 结果渲染成单独卡片，而不是普通消息

这使 DeerFlow 具备“一个 agent 负责编排，多个 agent 并行做事”的能力。

## 13. Custom Agent 系统

自定义 Agent 的 CRUD 在：

- `backend/app/gateway/routers/agents.py`

每个自定义 agent 对应一个目录：

```text
agents/{name}/
├── config.yaml
└── SOUL.md
```

其中：

- `config.yaml` 定义描述、模型覆盖、tool group 白名单
- `SOUL.md` 定义该 agent 的身份、语气、行为边界

前端通过：

- `frontend/src/core/agents/api.ts`

管理这些 agent。

这说明 DeerFlow 的“多 Agent”有两层含义：

- 运行时 subagent：执行具体任务
- 配置型 custom agent：定义一个新的长期可用 agent persona

## 14. Gateway API 的定位

Gateway 入口是：

- `backend/app/gateway/app.py`

它本质上是一个“资源与扩展管理 API”，而不是 Agent API。本项目把不适合放在 LangGraph 图里的功能放在这里，主要包括：

- models
- mcp
- memory
- skills
- artifacts
- uploads
- threads
- agents
- suggestions
- channels

这种拆分有几个好处：

- LangGraph runtime 可以专注消息流和 tool execution
- REST 资源更容易独立测试和演进
- 前端对非聊天功能可以直接用普通 fetch / React Query

## 15. IM Channels

IM channel 桥接代码在：

- `backend/app/channels/`

启动入口挂在 Gateway lifespan 中：

- `start_channel_service()`

支持的 channel 当前有：

- Feishu
- Slack
- Telegram

`ChannelService` 负责：

- 从 `config.yaml` 的 `channels` 段读取配置
- 创建 channel 实例
- 启动 `ChannelManager`
- 管理 `MessageBus` 与 `ChannelStore`

它们的作用是把 DeerFlow 从“网页聊天应用”扩展成“多入口 agent 平台”。

也就是说，Gateway 不只是给前端服务，还承担了 IM 集成宿主的角色。

## 16. 前端架构

### 16.1 技术分层

前端采用：

- Next.js App Router
- React 19
- TanStack Query
- LangGraph SDK

目录分层比较清晰：

```text
frontend/src/
├── app/          # 页面路由
├── components/   # UI 组件
├── core/         # 业务能力与 API 访问
├── hooks/        # 通用 hooks
├── lib/          # 工具函数
└── styles/       # 样式
```

其中最重要的是 `core/` 目录，它相当于前端的“应用服务层”。

### 16.2 前端业务层组织方式

`frontend/src/core/` 按领域拆分：

- `api/`：LangGraph SDK client 和流模式兼容层
- `threads/`：thread stream、线程列表、导出等
- `artifacts/`：产物加载
- `uploads/`：文件上传 API
- `models/`：模型列表 API
- `skills/`：技能列表与开关
- `agents/`：自定义 agent API
- `mcp/`：MCP 配置 API
- `memory/`：memory 相关 API
- `settings/`：本地设置持久化
- `tasks/`：subtask 状态共享

这个分层的好处是，组件层基本只关注渲染，网络调用和状态拼装尽量沉到底层 hooks/API 中。

### 16.3 Workspace 布局

主工作区布局在：

- `frontend/src/app/workspace/layout.tsx`

它负责：

- 注入 React Query `QueryClientProvider`
- 注入 Sidebar 状态
- 渲染全局命令面板
- 渲染全局 Toaster

聊天页再在其内部叠加：

- 消息区
- 输入区
- 待办区
- 产物侧栏

这使工作区具备典型 IDE/agent workspace 的形态，而不是单栏式聊天界面。

### 16.4 消息渲染层

消息渲染入口在：

- `frontend/src/components/workspace/messages/message-list.tsx`

它会把 LangGraph 返回的消息进一步分组为：

- 普通 human / assistant 消息
- clarification 消息
- present-files 消息
- subagent 消息

这说明 DeerFlow 前端不是把 AI 输出简单 markdown 渲染，而是有一层“消息语义解释器”，把工具调用结果映射成不同 UI 组件。

## 17. 配置体系

### 17.1 主配置

主配置文件是：

- `config.yaml`

由 `AppConfig` 负责解析，承载：

- models
- sandbox
- tools
- tool_groups
- skills 配置
- tool_search
- summarization
- memory
- subagents
- guardrails
- checkpointer
- 以及额外扩展字段（例如 channels）

### 17.2 扩展配置

扩展配置文件是：

- `extensions_config.json`

由 `ExtensionsConfig` 负责解析，承载：

- MCP server 配置
- skill enabled 状态

这种双配置文件设计很有针对性：

- `config.yaml` 偏静态、系统级、启动级配置
- `extensions_config.json` 偏动态、前端可管理的扩展状态

### 17.3 路径与环境变量

路径相关统一收口在：

- `deerflow.config.paths`

环境变量解析则由：

- `AppConfig.resolve_env_variables()`
- `ExtensionsConfig.resolve_env_variables()`

负责。

所以这个项目虽然配置项很多，但整体不是分散硬编码，而是通过 config model + path manager 做统一收口。

## 18. 部署与运行模式

### 18.1 本地开发模式

本地开发用：

- `make dev`

对应 `scripts/serve.sh --dev`，特点是：

- Frontend 用 Next dev
- Gateway 用 Uvicorn reload
- LangGraph 用 `langgraph dev`
- Nginx 做本地代理

### 18.2 Docker 开发模式

Docker 开发编排在：

- `docker/docker-compose-dev.yaml`

服务包括：

- `nginx`
- `frontend`
- `gateway`
- `langgraph`
- 可选 `provisioner`

### 18.3 生产模式

生产 compose 在：

- `docker/docker-compose.yaml`

整体仍然维持同样的服务拆分，只是改成生产镜像和只读挂载方式。

### 18.4 Provisioner 模式

如果使用 Kubernetes 托管 sandbox，则还会启用：

- `docker/provisioner/app.py`

这个服务负责：

- 为每个 sandbox 创建 Pod + Service
- 返回可访问的 sandbox URL
- 管理其生命周期

也就是说，DeerFlow 的 sandbox 抽象并不绑定于“本地子进程”或“本地 Docker 容器”，而是预留了远端/集群化执行能力。

## 19. 为什么这个架构成立

从工程角度看，这个项目的架构有几个很明确的设计原则。

### 19.1 把 Agent Runtime 和资源管理分开

聊天执行走 LangGraph，资源管理走 Gateway。这样避免把上传、产物、扩展配置、Agent CRUD 之类的事务性逻辑塞进图运行时。

### 19.2 用线程目录作为统一数据平面

无论是上传文件、Sandbox 执行、输出产物、前端查看，最终都围绕 thread 目录展开。这让很多跨模块协作问题变得简单。

### 19.3 用 middleware 管横切关注点

Summarization、Memory、Title、Clarification、Loop Detection、Guardrails 都被抽成 middleware，主 agent 逻辑保持可组装。

### 19.4 用 skills + config 保持扩展性

DeerFlow 既支持代码级扩展（tool、provider、sandbox、channel），也支持低代码扩展（skills、custom agent、MCP server 开关）。

## 20. 快速建立心智模型

如果要快速理解整个项目，可以用下面这套心智模型：

- `frontend/`：工作区 UI，直接连 LangGraph 做聊天流，连 Gateway 做资源管理
- `backend/app/gateway/`：REST 外围服务，管理配置、文件、产物、线程清理、Agent、技能、渠道
- `backend/packages/harness/deerflow/`：真正的 DeerFlow 核心，负责 agent runtime、tool、memory、sandbox、skills、subagents、models
- `skills/`：提示词型能力包
- `backend/.deer-flow` 或 `DEER_FLOW_HOME`：运行时持久化数据根目录
- `docker/` + `scripts/`：部署和启动编排

如果只看一句话：

> DeerFlow 是一个“前端工作区 + Gateway 资源层 + LangGraph Agent Runtime + 线程级沙箱文件系统”的多层系统，所有高级能力基本都建立在这个分层之上。

## 21. 建议的阅读顺序

如果你后面还要继续深入源码，推荐按这个顺序看：

1. `README.md`
2. `scripts/serve.sh`
3. `docker/nginx/nginx.local.conf`
4. `backend/langgraph.json`
5. `backend/packages/harness/deerflow/agents/lead_agent/agent.py`
6. `backend/packages/harness/deerflow/agents/lead_agent/prompt.py`
7. `backend/packages/harness/deerflow/tools/tools.py`
8. `backend/packages/harness/deerflow/config/paths.py`
9. `backend/app/gateway/app.py`
10. `backend/app/gateway/routers/uploads.py` / `artifacts.py` / `skills.py` / `agents.py`
11. `frontend/src/core/threads/hooks.ts`
12. `frontend/src/app/workspace/chats/[thread_id]/page.tsx`
13. `frontend/src/components/workspace/messages/message-list.tsx`

按这个顺序看，基本能把“请求怎么进来、Agent 怎么跑、文件怎么落地、前端怎么展示”串起来。
