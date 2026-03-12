# Supabase — EchoThink 的实时数据平台

## 概述与定位

Supabase 在 EchoThink 平台中的定位远超一个简单的"数据库封装层"——它是一个完整的应用数据平台，为人类团队与 AI 智能体之间的实时协作提供了从数据存储、自动化 API 生成到实时事件推送的全栈能力。在一个游戏开发团队的日常工作中，数据流转的速度直接决定了协作的效率：当一个 AI 智能体在 Dify 中完成了一段游戏对话的生成，这个结果需要立即被策划在文档工具中看到；当美术资源被上传到存储系统，前端构建流水线需要即时感知并触发更新。Supabase 的实时能力使得这些场景成为可能，它就像 EchoThink 平台的神经系统，将各个服务节点的数据变化以毫秒级的延迟传递到所有需要感知这些变化的订阅者手中。

EchoThink 部署的 Supabase 并非一个单一容器，而是由七个功能各异的微服务组成的完整生态。这些服务协同工作，共同构成了一个自托管的 Supabase 实例，其功能完全对标 Supabase 的云托管版本，但所有数据都安全地存储在团队自己控制的基础设施中——这对于涉及未公开游戏创意和知识产权的游戏开发团队而言，是一个不可妥协的要求。

## Kong — API 网关层

Kong（版本 2.8.1）是 Supabase 所有 API 请求的统一入口，它以声明式配置（DBless 模式）运行，通过挂载的 `kong.yml` 配置文件定义所有路由规则。Kong 对外暴露 8000（HTTP）和 8443（HTTPS）端口，并监听 8100 端口提供健康状态检查。在 EchoThink 的部署中，Kong 同时连接了 `echothink-internal` 和 `echothink-public` 网络，作为 Supabase 生态对外服务的唯一网络边界。

Kong 的路由配置将不同的 API 路径分发到对应的后端服务。`/auth/v1/` 路径下的请求被转发到 GoTrue 认证服务，`/rest/v1/` 路径的请求由 PostgREST 处理，`/realtime/v1/` 路径的 WebSocket 连接被路由到 Realtime 服务，`/storage/v1/` 路径的文件操作请求发往 Storage 服务，而 `/pg/` 路径则指向 Postgres Meta 服务。每个路由都配置了基于 API Key 的认证插件（`key-auth`）和访问控制列表（`acl`），系统预定义了两个消费者角色：`ANON`（匿名角色，属于 `anon` 组）和 `SERVICE_ROLE`（服务角色，属于 `admin` 组）。REST 和 Storage 路由还额外配置了 JWT 插件，用于验证请求中携带的 access_token 的有效性和角色声明。值得注意的是，Auth 服务中的 `/verify`、`/callback` 和 `/authorize` 三个端点被配置为开放路由（仅启用 CORS 插件而不要求认证），这是因为这些端点需要在用户尚未持有有效凭证时被访问——它们正是认证流程本身的组成部分。

CORS 插件在全局范围内启用，允许所有来源的跨域请求，支持常见的 HTTP 方法和请求头，凭证传递（credentials）设为 true，预检请求的缓存时间为 3600 秒。这种宽松的 CORS 配置适合开发和内部使用环境，在面向公网部署时应当收紧来源白名单。

## GoTrue — 用户认证引擎


## PostgREST — 自动生成的 REST API

PostgREST（版本 v14.5）是 Supabase 最具魅力的组件之一。它直接连接到 PostgreSQL 数据库，自动将数据库的表结构映射为一套完整的 RESTful API，无需编写任何后端代码。在 EchoThink 的配置中，PostgREST 暴露了 `public` 和 `graphql` 两个 schema，使用 `anon` 作为匿名角色，并在额外搜索路径中包含了 `extensions` schema。这意味着团队在 Supabase 数据库中创建的任何表，都会自动获得支持过滤、排序、分页和嵌套查询的 REST API 端点。

对于游戏开发团队而言，这种自动化 API 生成的能力极大地降低了原型验证的成本。策划可以直接在 Supabase Studio 中设计游戏配置表——角色属性、道具参数、关卡规则——然后立即通过 REST API 在游戏客户端中读取这些数据，完全跳过了传统开发流程中"等后端写接口"的等待环节。PostgREST 的权限控制完全依赖 PostgreSQL 的 Row Level Security（RLS）机制，这意味着数据的访问控制逻辑直接定义在数据库层面，与 API 层完全解耦，既简洁又安全。

## Realtime — 实时事件推送

Supabase Realtime（版本 v2.76.5）运行在 4000 端口，基于 Elixir/Phoenix 框架构建，为 EchoThink 平台提供基于 WebSocket 的实时数据同步能力。它监听 PostgreSQL 的逻辑复制流（logical replication），当数据库中的行被插入、更新或删除时，相应的变更事件会被实时推送到所有订阅了该表或该行的客户端。在配置中，Realtime 使用独立的 `_realtime` schema 存储其内部状态，并通过 `DB_AFTER_CONNECT_QUERY` 在每次数据库连接建立后自动设置搜索路径。

在游戏开发场景中，Realtime 的价值体现在多个层面。当多个策划同时编辑同一份关卡配置时，每个人的修改都会通过 Realtime 通道即时同步到其他人的界面上，实现类似 Google Docs 的协同编辑体验。更重要的是，当 AI 智能体在后台完成了一项异步任务（例如生成了一批 NPC 对话或者完成了一轮自动化测试），任务结果可以通过 Realtime 通道即时通知到等待中的人类团队成员，消除了传统轮询机制带来的延迟和资源浪费。

## Storage — S3 兼容的文件存储

Supabase Storage（版本 v1.37.8）提供了一套与 Supabase 认证体系深度集成的文件存储 API。在 EchoThink 中，Storage 服务被配置为使用 MinIO 作为 S3 兼容的后端存储，通过 `GLOBAL_S3_ENDPOINT` 指向内部 MinIO 服务（`http://minio:9000`），并开启了强制路径风格（Path Style）以兼容 MinIO 的寻址方式。Storage 支持最大 50MB 的文件上传（`FILE_SIZE_LIMIT: 52428800`），并集成了 imgproxy（v3.8.0）服务来提供动态图片转换能力，包括尺寸调整、格式转换（支持 WebP 自动检测）等操作。

对于游戏团队来说，Storage 服务可以用来管理概念原画、UI 素材、音效文件等游戏资产。通过 Supabase 的 Row Level Security 策略，可以精确控制哪些用户或 AI 智能体有权上传、下载或删除特定存储桶中的文件。imgproxy 的集成则使得前端可以按需请求不同尺寸的图片缩略图，而无需预先生成多套分辨率的资源——这在游戏 UI 原型快速迭代阶段特别有用。

## Studio 与 Meta — 可视化管理

Supabase Studio（版本 2026.02.16）是一个基于 Next.js 构建的 Web 管理界面，运行在 3000 端口，提供了对数据库表、策略、存储桶和 Realtime 通道的可视化管理能力。Studio 内部通过 Postgres Meta（版本 v0.95.2）服务获取数据库的元数据信息（表结构、索引、约束等），并通过 Kong 网关访问其他 Supabase 服务。Studio 的默认组织名称和项目名称分别被配置为"EchoThink"和"EchoThink Platform"，使得团队在进入管理界面时能够立即感受到这是一个统一平台的有机组成部分。

## Claw Cluster 与实时协作的未来

即将上线的 Claw Cluster（AI 员工集群）将充分释放 Supabase 实时数据平台的潜力。作为 EchoThink 的智能核心，Claw Cluster 中的 AI 智能体将通过 Supabase Realtime 建立与人类团队成员之间的双向实时通信通道。当策划在 Supabase 的游戏配置表中修改了一个关卡参数，订阅了该表的测试 Agent 将即时感知到变化并自动触发一轮回归测试；当 AI 剧情写手完成了一段支线任务的对话文本，结果会通过 Realtime 通道实时推送到策划的审阅界面。PostgREST 自动生成的 REST API 将成为 Claw Cluster 中各 AI 智能体访问结构化数据的标准接口——它们可以通过简单的 HTTP 请求读写游戏配置、任务状态和协作记录，而 Row Level Security 确保每个智能体只能触及自己职责范围内的数据。

这种架构将人与 AI 的协作从"轮询-拉取"模式升级为"订阅-推送"模式，大幅降低了协作延迟，使得 AI 智能体真正成为团队中实时参与协作的"数字同事"，而非需要定期手动检查输出的后台工具。

## 关键配置参考

Kong API 网关端口：8000（HTTP）、8443（HTTPS）、8100（健康检查）
Studio 管理界面端口：3000
GoTrue 认证服务端口：9999
PostgREST 服务端口：3000（内部）
Realtime 服务端口：4000
Storage 服务端口：5000（内部）

核心环境变量：
- `SUPABASE_JWT_SECRET` — JWT 签名密钥，所有 Supabase 组件共享
- `SUPABASE_ANON_KEY` — 匿名角色的 API Key
- `SUPABASE_SERVICE_ROLE_KEY` — 服务角色的 API Key（拥有管理员权限）
- `SUPABASE_DB_PASSWORD` — 数据库密码
- `SUPABASE_DB_HOST` — 数据库主机（默认 `postgres`）
- `SUPABASE_DB_NAME` — 数据库名称（默认 `supabase`）
- `SUPABASE_PUBLIC_URL` — Supabase 对外访问的公共 URL

持久化卷：`supabase-storage-data`

Kong 配置文件位置：`services/supabase/volumes/kong.yml`
