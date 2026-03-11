# PostgreSQL — EchoThink 的数据基座

## 概述

PostgreSQL 是 EchoThink 整个基础设施栈的数据核心。我们选择了 PostgreSQL 16 作为唯一的关系型数据库引擎，并在此基础上编译安装了 pgvector 扩展，使其同时具备传统关系型查询与高维向量检索的双重能力。在游戏设计与 AI 协作的场景中，这意味着团队不需要为结构化的项目管理数据和非结构化的 AI embedding 向量分别维护两套数据库系统——一个 PostgreSQL 实例即可覆盖所有需求。这种"聚合式数据库"的架构理念贯穿了 EchoThink 的设计哲学：通过减少基础设施组件的数量来降低运维复杂度，同时保持每个组件的专业深度。

EchoThink 的 PostgreSQL 实例基于官方 `postgres:16.13-bookworm` 镜像构建自定义 Docker 镜像。构建过程中安装了 `postgresql-16-pgvector` 包以及必要的编译工具链。初始化脚本和自定义配置文件在镜像构建阶段被复制到容器中，确保每次容器启动时都能以完全一致的状态进入服务。容器启动命令显式指定了配置文件路径 `/etc/postgresql/postgresql.conf`，覆盖 PostgreSQL 的默认配置，以便我们对内存分配、连接数、WAL 策略等关键参数进行精细调优。

## 九库共存的多租户架构

EchoThink 平台的所有上层服务共享同一个 PostgreSQL 实例，但每个服务拥有独立的数据库和专属的登录角色。初始化脚本 `01-databases.sql` 在首次启动时创建九个数据库：`supabase`、`hatchet`、`langfuse`、`n8n`、`authentik`、`dify`、`outline`、`litellm` 和 `gitlab`。这九个数据库分别服务于平台的不同功能模块——Supabase 提供实时数据同步与后端即服务能力，Hatchet 承担任务编排与工作流引擎的职责，Langfuse 记录和分析 AI 调用的可观测性数据，n8n 驱动自动化工作流，Authentik 管理身份认证与单点登录，Dify 作为 AI 应用开发平台存储对话与知识库数据，Outline 托管团队的知识维基，LiteLLM 作为大语言模型统一网关记录路由与用量数据，GitLab 则管理所有代码仓库和 CI/CD 流水线的元数据。

每个数据库在创建后都会立即激活一组标准扩展：`vector`（pgvector 向量索引）、`pg_trgm`（三元组文本相似度搜索）、`btree_gist`（GiST 索引支持）、`pg_stat_statements`（查询性能统计）和 `uuid-ossp`（UUID 生成）。这样的统一扩展配置确保每个服务都能在需要时直接使用向量检索或模糊文本匹配功能，而不需要额外的数据库管理员介入。

## 最小权限的角色体系

安全性是多服务共享数据库时必须严肃对待的问题。`02-roles.sql` 脚本为每个服务创建了专属的数据库角色：`supabase_admin`、`hatchet_user`、`langfuse_user`、`n8n_user`、`authentik_user`、`dify_user`、`outline_user`、`litellm_user` 和 `gitlab_user`。每个角色仅被授予其对应数据库的全部权限，并被设置为该数据库的 owner，同时拥有 public schema 的完全控制权。但关键在于，任何一个服务角色都无法访问其他服务的数据库。这种最小权限原则意味着即使某个服务的凭据遭到泄露，攻击者也无法横向移动到其他服务的数据中。

角色密码在初始化脚本中以占位符形式存在，实际部署时由 `init.sh` 脚本在首次运行前替换为随机生成的强密码。各服务通过环境变量获取各自的数据库连接凭据，遵循 `<SERVICE>_DB_HOST`、`<SERVICE>_DB_USER`、`<SERVICE>_DB_PASSWORD` 的命名约定。

## 性能调优配置

EchoThink 的 PostgreSQL 配置经过仔细调优，以适应多服务共享的聚合工作负载。连接数上限设置为 `max_connections = 300`，这个数字是根据九个服务各自的连接池需求综合计算得出的——每个服务通常维持 20-30 个连接，加上管理和监控连接的开销，300 个连接提供了充足的余量。共享缓冲区 `shared_buffers` 设置为 1GB，有效缓存大小 `effective_cache_size` 为 3GB，这两个参数告诉查询规划器可以合理地预期大量数据已经驻留在内存中，从而倾向于使用索引扫描而非顺序扫描。工作内存 `work_mem` 为 16MB，维护内存 `maintenance_work_mem` 为 256MB，前者影响排序和哈希操作的内存分配，后者影响 VACUUM 和索引创建等维护操作的效率。

WAL（预写式日志）配置是另一个关键区域。`wal_level` 被设置为 `logical`，这是 Supabase Realtime 功能所必需的——逻辑复制允许 Supabase 实时监听数据库变更并将其推送到客户端。`max_wal_senders` 和 `max_replication_slots` 各设置为 10，为 Supabase 的多个 Realtime 频道提供充足的复制槽位。WAL 缓冲区为 16MB，最小和最大 WAL 大小分别为 1GB 和 4GB，检查点完成目标为 0.9，这些参数共同确保了写入密集型工作负载下的稳定性能。

日志配置方面，超过 1000 毫秒的慢查询会被记录，检查点、连接、断开、锁等待和临时文件等事件也会被记录。自动清理（autovacuum）以较为激进的阈值运行，vacuum 和 analyze 的比例因子分别设置为 0.02 和 0.01，确保表的统计信息始终保持最新，查询规划器能做出最优决策。`pg_stat_statements` 扩展被预加载，最多追踪 10000 条查询的统计信息，为性能分析和优化提供数据基础。

容器层面，`shm_size` 被设置为 256MB，确保 PostgreSQL 有足够的共享内存用于进程间通信。健康检查使用 `pg_isready` 命令，每 10 秒执行一次，超时 5 秒，最多重试 5 次，启动等待期为 30 秒。数据通过命名卷 `postgres-data` 持久化存储。

## 游戏开发中的应用价值

对于专注游戏设计与开发的团队而言，PostgreSQL 的聚合架构带来了显著的实际价值。游戏资产的元数据——包括纹理规格、模型多边形数、音频采样率、动画帧数等结构化信息——自然地存储在关系型表中，并可通过复杂的 SQL 查询进行精确检索和统计分析。与此同时，AI 生成的内容（如角色设定文本、剧情大纲、关卡描述等）可以通过 pgvector 转化为高维向量存储，使团队能够通过语义相似度搜索快速找到相关的设计素材。例如，设计师可以用自然语言描述"暗黑风格的哥特式城堡场景"，系统就能通过向量检索找到所有语义相近的已有场景设计文档、概念艺术描述和关卡配置。

玩家数据的管理同样受益于这种架构。Supabase 利用 PostgreSQL 的逻辑复制功能提供实时数据同步，这意味着游戏的在线状态、排行榜、成就系统等都可以基于 Supabase Realtime 实现毫秒级的数据推送。Dify 平台上构建的 AI 角色对话系统则利用同一个 PostgreSQL 实例中的知识库功能存储和检索游戏世界观资料，确保 AI NPC 的回应始终与游戏设定保持一致。

## Claw Cluster 集成展望

即将上线的 Claw Cluster（AI 员工集群）将成为 EchoThink 平台的智能核心，而 PostgreSQL 是它最重要的数据接口之一。Claw Cluster 中的 AI 代理将拥有对所有九个数据库的读取权限，以及对特定工作数据库的写入权限，使它们能够跨服务地理解和关联信息。其中，pgvector 的语义搜索能力将是 Claw Cluster 最核心的工具——AI 代理可以在 Outline 知识库、Dify 对话历史、GitLab 代码注释和 Langfuse 调用记录中进行统一的语义检索，将散落在不同系统中的相关信息串联起来，形成对项目状态的全局理解。这种跨服务的语义搜索能力是传统关键词检索无法实现的，它使 AI 代理能够真正像一个有经验的团队成员那样，在海量的项目资料中快速定位最相关的信息，为游戏设计决策提供高质量的参考和建议。

## 关键配置速查

- 基础镜像：`postgres:16.13-bookworm` + pgvector
- 容器名称：`echothink-postgres`
- 端口：5432（仅内部网络可访问）
- 最大连接数：300
- 共享缓冲区：1GB
- WAL 级别：logical
- 数据卷：`postgres-data`
- 网络：`echothink-internal`
- 数据库数量：9 + 1（默认 postgres 库）
- 扩展：vector, pg_trgm, btree_gist, pg_stat_statements, uuid-ossp
