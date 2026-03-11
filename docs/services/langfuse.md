# Langfuse — EchoThink 的 AI 可观测性平台

## 平台定位与核心价值

Langfuse 3 是 EchoThink 基础设施中的 AI 可观测性与分析平台，专注于对所有大语言模型调用进行追踪、分析和成本监控。在一个深度依赖 AI 能力的游戏开发团队中，每天可能发生成百上千次 LLM 调用——从对话文本生成到美术资产描述，从代码审查建议到数值平衡计算——如果缺乏系统化的观测手段，团队将无法回答一些关键问题：哪些 AI 任务的耗费最高？哪些提示词模板产出的质量最好？某次生成质量骤降的原因是什么？Langfuse 的存在正是为了让这些问题有据可查。

Langfuse 3 相比前代版本引入了双存储架构，使用 PostgreSQL 存储元数据和用户配置，同时使用 ClickHouse 存储高频的追踪事件和分析数据。这种架构分离使得 Langfuse 能够同时满足事务性查询的一致性需求和分析型查询的高性能需求。对于我们的团队而言，这意味着在 Langfuse 的管理界面上既可以精确地查找某一次特定的 LLM 调用详情，也可以高效地分析过去一个月所有图像生成任务的成本趋势，两种查询模式互不影响。

## 容器架构与存储设计

Langfuse 在 EchoThink 中由两个容器协同工作，分别承担应用服务和分析存储的职责。

ClickHouse 容器（langfuse-clickhouse）运行 ClickHouse 25.3 版本，作为 Langfuse 的分析引擎和事件存储后端。ClickHouse 是一款面向列式存储的分析型数据库，特别擅长处理大规模时序数据的聚合查询，非常适合存储和分析 LLM 调用的追踪事件。容器配置了 `langfuse` 数据库和对应的用户凭据，数据持久化到 `langfuse-clickhouse-data` 卷中。ClickHouse 的配置文件中启用了内置的 Keeper 协调服务（端口 9181），配置了单节点的 Raft 集群用于元数据同步，并通过 `listen_host` 设置为 `0.0.0.0` 确保仅监听 IPv4 以避免 IPv6 不可用时的启动延迟。健康检查通过 wget 探测 8123 端口的 `/ping` 端点，启动等待时间设置了充裕的 90 秒，最大重试 10 次，因为 ClickHouse 在首次启动时需要初始化存储引擎和执行 schema 创建。

Langfuse 主容器运行 `langfuse/langfuse:3` 镜像，在 3000 端口上提供 Web 界面和 API 服务，同时映射到宿主机的 127.0.0.1:3100 端口用于本地访问。它依赖 ClickHouse 和 PostgreSQL 两个数据库容器都通过健康检查后才会启动。Langfuse 容器同时连接到 echothink-internal 和 echothink-public 两个网络，通过 Nginx 反向代理在 `langfuse.${DOMAIN}` 域名下对外提供服务。健康检查通过 Node.js 脚本调用 `/api/public/health` 端点，启动等待时间设为 300 秒（5 分钟），反映了 Langfuse 3 在首次启动时需要执行 PostgreSQL 和 ClickHouse 双重数据库迁移的时间开销。

## 双存储架构详解

Langfuse 3 的双存储架构是其技术设计中最值得深入理解的部分。PostgreSQL 连接通过 `DATABASE_URL` 配置，指向 EchoThink 共享的 PostgreSQL 实例中的 `langfuse` 数据库，用户为 `langfuse_user`。这个数据库存储项目配置、用户账户、API 密钥、提示词模板和评估标准等需要事务一致性保证的结构化数据。

ClickHouse 通过两个不同的连接地址提供服务：HTTP 接口（`http://clickhouse:8123`）用于运行时的数据读写，原生协议接口（`clickhouse://clickhouse:9000/langfuse`）用于执行数据库迁移。当前配置中 ClickHouse 集群模式已关闭（`CLICKHOUSE_CLUSTER_ENABLED: false`），适合单节点部署场景。ClickHouse 中存储的是高频写入的追踪事件数据——每一次 LLM 调用的输入输出、token 消耗、延迟时间、模型参数等细粒度信息都会写入 ClickHouse，其列式存储引擎能够高效地压缩这些时序数据并快速执行聚合分析。

Redis 也是 Langfuse 3 的必要组件（`REDIS_CONNECTION_STRING: redis://redis:6379`），用于缓存、会话管理和实时事件处理。这三个存储后端各司其职：Redis 负责热数据和实时性需求，PostgreSQL 负责结构化元数据和事务操作，ClickHouse 负责海量追踪数据的存储和分析查询。

## 追踪体系与成本监控

Langfuse 的核心功能围绕 Trace、Span 和 Generation 三个层级的追踪体系展开。一个 Trace 代表一次完整的用户请求或业务操作（例如"生成一段 NPC 对话"），它可以包含多个 Span（子步骤），每个 Span 下可以有一个或多个 Generation（具体的 LLM 调用）。这种层级结构使得团队可以从宏观到微观地观察 AI 系统的行为：在 Trace 层面了解整体执行耗时和成本，在 Span 层面定位哪个步骤是性能瓶颈，在 Generation 层面分析具体的 LLM 输入输出和 token 消耗。

成本监控是 Langfuse 为团队带来的最直接的价值之一。每一次 LLM 调用的 token 消耗都会被精确记录，结合模型定价信息可以计算出每次调用的实际成本。团队可以按项目、按应用、按时间段查看成本分布，识别出成本异常的任务和优化空间。例如，如果发现某个对话生成工作流的平均成本远高于预期，可以通过 Langfuse 深入分析每个步骤的 token 消耗，找出是否存在不必要的上下文传递或过于冗长的系统提示词。

与 LiteLLM 的集成是 Langfuse 在 EchoThink 中发挥全面观测能力的关键。LiteLLM 作为所有 AI 服务的模型网关，天然支持将调用追踪数据发送到 Langfuse。这意味着无论是 Dify 的工作流调用、Graphiti 的实体提取调用，还是其他任何通过 LiteLLM 访问模型的服务，其所有 LLM 调用都会自动出现在 Langfuse 的追踪面板中，无需各服务单独集成。

## 对象存储与安全配置

Langfuse 通过 MinIO 对象存储服务存储两类数据：事件数据和媒体文件。事件上传使用 `langfuse-events` 存储桶，当追踪事件的数据量较大或包含大段文本时，Langfuse 会将其存入 MinIO 而非直接写入数据库，避免数据库膨胀。媒体上传使用 `langfuse-media` 存储桶，存储与追踪关联的图片、音频等多媒体文件。两者都配置了 path-style 访问模式（`FORCE_PATH_STYLE: true`），与 EchoThink 中 MinIO 的统一访问方式保持一致。

安全方面，Langfuse 配置了多层加密保护。`ENCRYPTION_KEY` 提供 256 位的 AES 加密密钥（64 位十六进制字符），用于加密存储在数据库中的敏感信息。`NEXTAUTH_SECRET` 用于签名和验证认证会话令牌。`SALT` 用于 API 密钥的哈希存储。此外 Langfuse 还集成了 Authentik OIDC 认证，配置了完整的 OAuth2 客户端参数，支持通过 EchoThink 的统一身份认证系统登录，并允许与本地账户自动关联（`AUTH_CUSTOM_ALLOW_ACCOUNT_LINKING: true`）。同时保留了用户名密码登录方式作为备选（`AUTH_DISABLE_USERNAME_PASSWORD: false`），确保在 SSO 服务不可用时仍能访问系统。

## 游戏开发场景中的应用

在游戏开发团队的日常工作中，Langfuse 的可观测性能力直接服务于 AI 生成质量的持续优化。当美术团队反映"最近 AI 生成的角色描述质量明显下降"时，Langfuse 可以快速定位问题：是模型切换导致的？是提示词被意外修改了？还是输入数据的格式发生了变化？通过对比不同时间段的 Generation 记录，团队可以精确找到质量变化的拐点和原因。

提示词优化是另一个重要应用场景。团队可以在 Langfuse 中对比不同提示词模板产出的结果质量和成本效率，找到最优的提示词配置。例如，对于物品描述生成任务，可以同时测试简洁型和详细型两种提示词模板，通过 Langfuse 的评分功能对输出质量进行标注，最终用数据驱动的方式选择最佳方案。

跨服务的成本分摊同样依赖 Langfuse 的追踪数据。当需要向管理层汇报 AI 投入产出比时，Langfuse 能够提供按任务类型（对话生成、美术描述、代码审查等）分类的成本明细，帮助团队做出资源配置的决策。

## Claw Cluster 集成展望

Claw Cluster（AI 员工集群）的每一次 LLM 调用都将通过 Langfuse 进行全链路追踪。作为 EchoThink 的智能核心，Claw Cluster 中运行的所有 AI Agent 产生的模型调用都将被自动记录到 Langfuse 中，提供对 AI 员工行为的完整可见性。团队不仅能够看到每个 Agent 消耗了多少 token 和费用，还能深入到每一次决策的输入输出细节，理解 Agent 为什么做出了某个特定的选择。

成本分摊将按照 AI 员工维度进行组织，每个 Agent 的 LLM 消耗都有独立的追踪标记，使得管理层可以像查看真实员工的工时报表一样查看 AI 员工的资源消耗。质量指标将通过 Langfuse 的评分和评估功能持续监控，确保 AI 员工集群的输出始终满足团队的质量标准。当某个 Agent 的表现出现异常时，Langfuse 的追踪数据将帮助团队快速诊断问题、调整参数，保障 AI 员工集群的稳定高效运行。

## 关键配置参考

Langfuse Web 与 API 端口：3000（容器内）/ 3100（宿主机映射）
Langfuse 健康检查端点：`/api/public/health`
ClickHouse HTTP 端口：8123
ClickHouse 原生协议端口：9000
ClickHouse Keeper 端口：9181
PostgreSQL 数据库：`langfuse`，用户 `langfuse_user`
ClickHouse 数据库：`langfuse`
Redis：`redis://redis:6379`
事件存储桶：`langfuse-events`（MinIO）
媒体存储桶：`langfuse-media`（MinIO）
SSO 集成：Authentik OIDC（`https://auth.${DOMAIN}/application/o/langfuse/`）
