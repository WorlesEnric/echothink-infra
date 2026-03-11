# Hatchet — EchoThink 的分布式任务编排引擎

## 平台定位与核心价值

Hatchet 0.79.32 是 EchoThink 基础设施中的分布式任务编排引擎，负责将复杂的多步骤工作流拆解为可靠、可追踪的任务单元，分发给各个 Worker 执行，并确保每个任务在失败时能够自动重试或优雅降级。在一个以 AI 驱动游戏开发的团队中，日常工作充满了需要多步骤协调的复杂流程：一张概念设计图的生成可能需要经过提示词构建、模型调用、质量评审、迭代修改、最终存档等多个阶段，每个阶段都可能涉及不同的服务和工具。Hatchet 的存在让这些流程不再是脆弱的脚本链条，而是具备持久化状态、失败恢复和可观测性的正式工作流。

与简单的任务队列不同，Hatchet 提供的是真正的工作流编排能力。它理解任务之间的依赖关系，知道哪些步骤可以并行执行、哪些必须串行等待，能够在某个步骤失败后从断点恢复而非从头开始。这种持久化工作流（durable workflow）的特性对于游戏开发中那些耗时长、步骤多、成本高的 AI 生成流水线来说是不可或缺的。

## 容器架构与启动编排

Hatchet 在 EchoThink 中由四个核心服务容器和一个辅助工具容器组成，它们之间有严格的启动顺序依赖。整个启动流程体现了 Hatchet 对数据一致性和配置正确性的重视。

Setup 容器（hatchet-setup）使用 `hatchet-migrate` 镜像，负责执行数据库迁移。它连接到 PostgreSQL 中的 `hatchet` 数据库，运行完所有迁移脚本后自动退出。这是整个 Hatchet 启动链的第一步，确保数据库 schema 与当前版本完全匹配。

Config 容器（hatchet-config）在 Setup 成功完成且 PostgreSQL 健康检查通过后启动，使用 `hatchet-admin` 镜像执行 quickstart 命令，在 `/hatchet/config` 目录中生成引擎运行所需的配置文件。它跳过证书生成（`--skip certs`），并设置为不覆盖已有配置（`--overwrite=false`），这意味着首次启动时会自动生成配置，后续重启时保留已有的自定义修改。Config 容器配置了消息队列使用 PostgreSQL 模式（`SERVER_MSGQUEUE_KIND: postgres`），避免了额外引入消息队列中间件的复杂性。gRPC 广播地址设置为 `hatchet-engine:7070`，确保 Worker 连接到正确的引擎实例。

Engine 容器（hatchet-engine）是 Hatchet 的核心，负责工作流编排、任务调度和 Worker 管理。它通过 gRPC 协议在 7070 端口上与 Worker 通信，健康检查端点位于 `http://localhost:8733/ready`。Engine 同时使用 Setup 成功完成和 Config 成功完成作为启动前置条件，它挂载了证书和配置两个共享卷，确保能够读取到 Config 阶段生成的运行时配置。gRPC 绑定地址设为 `0.0.0.0`，使用非安全模式（`SERVER_GRPC_INSECURE: true`），因为在 Docker 内部网络中通信无需 TLS 加密。

API 容器（hatchet-api）提供 REST API 和 Web 管理界面，运行在 8080 端口。它不仅依赖 Setup 和 Config 成功完成，还要求 Engine 容器通过健康检查后才会启动，因为 API 层需要与 Engine 通信来展示工作流状态和管理任务。API 容器同时连接到 echothink-internal 和 echothink-public 网络，通过 Nginx 反向代理对外提供 `hatchet.${DOMAIN}` 域名的访问。

此外还有一个 Keygen 辅助容器（hatchet-keygen），它不会在正常启动流程中运行（配置了 `profiles: keygen`），仅在需要生成加密密钥时手动调用。它会输出生成 Cookie 密钥、Master 密钥集、JWT 私钥集和 JWT 公钥集的命令，团队按照提示执行后将结果设置为对应的环境变量。

## 持久化工作流与失败恢复

Hatchet 的持久化工作流执行是其区别于普通任务队列的核心特性。当一个工作流被提交后，Hatchet 会将其完整的执行状态持久化到 PostgreSQL 数据库中。每个步骤的输入、输出、执行状态和错误信息都被精确记录，即便 Engine 容器意外重启，工作流也能从上次中断的位置继续执行而非从头开始。这种设计在处理耗时较长的 AI 生成任务时尤为关键——想象一个需要一小时才能完成的大规模资产批量生成任务，如果在第 45 分钟时系统发生重启，没有人希望已完成的工作全部丢失。

Hatchet 的重试机制同样经过精心设计。开发者可以为每个工作流步骤配置独立的重试策略，包括最大重试次数、重试间隔和退避策略。对于调用外部 AI 模型这种可能因为限流或网络波动而临时失败的操作，自动重试能够大幅提高整体成功率。对于那些确实无法恢复的错误，Hatchet 支持配置失败处理回调，确保团队能够及时收到通知并采取行动。

## gRPC 通信与高性能任务分发

Hatchet Engine 通过 gRPC 协议与 Worker 建立长连接，这一设计选择带来了显著的性能优势。相比基于 HTTP 轮询的任务拉取模式，gRPC 的双向流通信使得 Engine 可以在任务就绪的瞬间将其推送给空闲的 Worker，消除了轮询延迟。同时 gRPC 的二进制序列化协议（Protocol Buffers）相比 JSON 有更小的传输开销和更快的解析速度，这在高频率任务分发场景下表现尤为明显。

Engine 在 7070 端口上监听来自 Worker 的 gRPC 连接，广播地址配置为 `hatchet-engine:7070`，这使得同一 Docker 网络内的任何 Worker 容器都可以通过这个地址注册并接收任务。V1 版本的引擎（`SERVER_DEFAULT_ENGINE_VERSION: V1`）带来了改进的调度算法和更好的并发处理能力。

## 安全与认证机制

Hatchet 的安全架构基于多层加密和 JWT 认证。Cookie 加密使用 base64 编码的随机密钥（`HATCHET_AUTH_COOKIE_SECRETS`），确保 Web 界面的会话管理安全。Master 密钥集（`HATCHET_ENCRYPTION_MASTER_KEYSET`）用于加密存储在数据库中的敏感数据。JWT 密钥对（私钥集和公钥集）用于 Worker 认证和 API 访问控制，确保只有持有合法令牌的 Worker 才能连接到 Engine 并接收任务。Cookie 域名设置为 `hatchet.${DOMAIN}`，与 Nginx 反向代理的域名配置一致。

## 游戏开发场景中的应用

在游戏开发的实际工作中，Hatchet 的任务编排能力可以应用于多种复杂流程。以美术资产生成流水线为例，一个完整的工作流可能包含以下阶段：接收策划需求文档、解析需求并生成提示词、调用图像生成模型、对生成结果进行质量评审、根据评审意见迭代修改、生成符合规范的资产元数据、最终将通过审核的资产存入项目仓库。这个流程中的每一步都是 Hatchet 工作流中的一个任务节点，部分步骤（如多个变体的并行生成）可以同时执行以提高效率，而关键的评审节点则必须等待前置步骤全部完成。

批量资产生成是另一个典型场景。当项目需要一次性生成数百个物品描述或角色立绘时，Hatchet 可以将这些请求拆分为独立的任务单元，分发给多个 Worker 并行处理，同时通过速率限制避免对 AI 模型服务造成过大压力。构建和测试流水线的编排同样是 Hatchet 的强项——代码编译、自动化测试、性能基准测试、部署到测试环境等步骤可以被编排为一个可靠的持久化工作流，任何步骤的失败都会触发通知而不会导致后续步骤在错误的基础上继续执行。

## Claw Cluster 集成展望

Claw Cluster（AI 员工集群）将以 Hatchet 作为任务分配和执行追踪的骨干系统。作为 EchoThink 的智能核心，Claw Cluster 中的每一个 AI Agent 都将作为 Hatchet 的 Worker 注册到 Engine，通过 gRPC 接收任务分配。当团队向某个 AI 员工下达工作指令时，这条指令会被转化为 Hatchet 工作流，Engine 负责将工作流中的各个步骤按照依赖关系调度给对应的 Agent Worker。每个 Agent 的工作进度、中间产出和最终结果都会被 Hatchet 持久化记录，团队可以在 Hatchet 的 Web 界面上实时查看每个 AI 员工的工作状态，就像查看真实员工的任务看板一样。这种持久化和可观测的任务执行模式确保了 AI 员工集群的工作既可靠又透明，任何一个 Agent 的意外中断都不会导致工作进度丢失。

## 关键配置参考

Engine gRPC 端口：7070
Engine 健康检查端点：`http://localhost:8733/ready`
API REST 端口：8080
API 健康检查端点：`http://localhost:8080/api/ready`
数据库：PostgreSQL `hatchet` 库，用户 `hatchet_user`
消息队列模式：PostgreSQL（无需额外 MQ 中间件）
配置卷：`hatchet-config`
证书卷：`hatchet-certs`
