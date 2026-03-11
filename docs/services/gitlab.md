# GitLab — EchoThink 的代码协作与 DevOps 平台

## 服务概述

GitLab 是 EchoThink 基础设施中的代码协作与 DevOps 平台，当前部署版本为 GitLab EE 18.9.1。作为一个完整的 DevOps 生命周期工具，GitLab 在单一平台内整合了代码版本管理、合并请求与代码审查、CI/CD 持续集成与持续部署、容器镜像仓库、Issue 跟踪与项目管理等核心能力。对于一个以游戏设计与开发为核心业务的团队来说，GitLab 不仅仅是一个存放源代码的地方——它是整个游戏开发工作流的中枢，从第一行代码的提交到最终构建包的产出，每一个环节都在 GitLab 的管控之下运行。

选择 GitLab Enterprise Edition 而非社区版，是因为 EE 版本提供了更丰富的安全审计、合规管理和高级 CI/CD 功能，这些能力在团队规模扩展和项目复杂度提升时会变得至关重要。游戏项目的代码仓库往往包含大量二进制资源文件（模型、贴图、音频等），GitLab 的 LFS（Large File Storage）支持让团队能够高效管理这些大文件，而不会导致仓库体积膨胀。结合 EchoThink 平台的 MinIO 对象存储后端，这些大文件被透明地存储在高性能对象存储中，既保证了 Git 操作的流畅性，又实现了数据的集中管理和备份。

## 部署架构与配置

GitLab 在 EchoThink 中以 Docker 容器形式部署，使用官方镜像 `gitlab/gitlab-ee:18.9.1-ee.0`。GitLab 内部的 Nginx 监听 8929 端口作为 HTTP 服务入口，同时容器的 22 端口映射到宿主机的 2222 端口用于 SSH 协议的 Git 操作。所有 HTTPS 流量通过 EchoThink 的统一 Nginx 反向代理处理，外部用户通过 `https://gitlab.${DOMAIN}` 访问 GitLab 界面。Nginx 配置中将 `client_max_body_size` 设为 250MB，以适应游戏开发中常见的大文件推送场景，代理读取和连接超时均设为 300 秒，确保大型仓库的克隆和推送操作不会因超时而中断。

GitLab 的内部 Nginx 被配置为仅监听 HTTP 协议（`nginx['listen_https'] = false`），因为 TLS 终结由前端的 EchoThink Nginx 代理统一处理。通过设置 `X-Forwarded-Proto` 和 `X-Forwarded-Ssl` 头部，GitLab 能够正确识别原始请求使用的是 HTTPS 协议，从而在生成回调 URL 和重定向链接时使用正确的协议前缀。这种 TLS 终结前移的架构设计简化了证书管理——整个平台只需在 Nginx 层面维护一套 TLS 证书即可。

在数据存储方面，GitLab 禁用了内置的 PostgreSQL 和 Redis，转而使用 EchoThink 的共享实例。数据库连接指向共享 PostgreSQL 中的 `gitlab` 数据库，由用户 `gitlab_user` 访问。Redis 连接使用共享实例的 database 1，与其他服务的 Redis 数据隔离。GitLab 定义了三个持久化数据卷：`gitlab-config` 存储 GitLab 的配置文件、`gitlab-logs` 存储运行日志、`gitlab-data` 存储仓库数据和应用数据。容器的共享内存大小（`shm_size`）设为 256MB，这是 GitLab 中 Prometheus 和 Puma 等组件正常运行所需的配置。健康检查通过 `gitlab-ctl status` 命令实现，启动等待期设为 300 秒（5 分钟），因为 GitLab 的初始化过程涉及数据库迁移和多个内部服务的依次启动，需要较长时间。

关键环境变量与端口信息如下：

- 内部 HTTP 端口：8929
- 内部 SSH 端口：22（映射到宿主机 2222）
- 外部访问：https://gitlab.${DOMAIN}（经 Nginx 反向代理）
- `GITLAB_DB_PASSWORD`：PostgreSQL 数据库连接密码
- `GITLAB_OAUTH_CLIENT_ID`：Authentik OIDC 客户端 ID
- `GITLAB_OAUTH_CLIENT_SECRET`：Authentik OIDC 客户端密钥
- `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD`：MinIO 对象存储访问凭证

## 对象存储与容器镜像仓库

GitLab 的对象存储功能通过 MinIO 实现了全面集成。在配置中启用了统一的对象存储（`object_store['enabled'] = true`），所有类型的对象数据都通过 S3 兼容协议存储在 MinIO 中。GitLab 为不同类型的数据创建了独立的存储桶，实现了数据分类管理：`gitlab-artifacts` 存储 CI/CD 构建产物、`gitlab-mr-diffs` 存储合并请求的差异数据、`gitlab-lfs` 存储 LFS 大文件、`gitlab-uploads` 存储用户上传的附件、`gitlab-packages` 存储软件包注册表的数据、`gitlab-dependency-proxy` 存储依赖代理缓存、`gitlab-terraform-state` 存储 Terraform 状态文件、`gitlab-pages` 存储 GitLab Pages 的静态站点数据。代理下载功能（`proxy_download`）已开启，用户下载这些对象时流量通过 GitLab 代理，无需直接暴露 MinIO 的访问端点。

GitLab 同时配置了容器镜像仓库（Container Registry），通过 `https://registry.${DOMAIN}` 提供 Docker 镜像的推送和拉取服务。Registry 内部 Nginx 监听 5050 端口，同样采用前端 TLS 终结的架构。这个镜像仓库在游戏开发中有着重要价值：团队可以将游戏服务器的 Docker 镜像、构建环境镜像和工具链镜像统一存储在私有仓库中，配合 CI/CD 管线实现镜像的自动构建和版本管理。

## 统一身份认证集成

GitLab 通过 OmniAuth 框架与 Authentik 实现了 OIDC 单点登录集成。配置中使用了条件判断逻辑——仅当 `GITLAB_OAUTH_CLIENT_ID` 和 `GITLAB_OAUTH_CLIENT_SECRET` 环境变量不为空时才启用 OmniAuth，这种设计保证了在 Authentik 尚未配置完成时 GitLab 仍能独立运行。启用后，GitLab 会自动允许通过 OIDC 进行单点登录，并自动从身份提供方同步用户的邮箱和个人资料信息。`omniauth_block_auto_created_users` 设为 false，意味着通过 Authentik 首次登录的用户会被自动创建 GitLab 账号，无需管理员手动审批。PKCE（Proof Key for Code Exchange）安全扩展已启用，为 OAuth 授权码流程增加了额外的安全层。

这种统一认证的集成让团队成员使用同一套 EchoThink 账号即可无缝访问 GitLab 和平台内的其他所有服务，消除了多系统账号管理的负担。当新成员加入团队时，管理员只需在 Authentik 中创建一个账号，该成员即可自动获得所有平台服务的访问权限。

## 游戏开发场景中的应用价值

对于游戏开发团队而言，GitLab 的价值远超传统的代码托管工具。在版本控制层面，游戏项目的代码仓库结构通常非常复杂——客户端代码、服务器代码、配置数据表、关卡编辑器脚本、构建工具链等模块可能分布在多个仓库或单一仓库的不同目录中，GitLab 的 Group 和 Subgroup 功能可以按照项目结构对仓库进行层次化组织。LFS 支持与 MinIO 后端的结合让团队能够将美术资源和音频文件纳入版本控制，实现"一切皆可追溯"的资产管理方式。

CI/CD 管线是 GitLab 在游戏开发中最具变革性的能力。团队可以构建全自动化的构建管线：代码提交自动触发编译和单元测试、合并请求自动运行集成测试和代码质量检查、合并到主分支后自动构建各平台（Windows、macOS、Linux、移动端）的游戏包并上传到分发渠道。Puma 工作进程数设为 2、Sidekiq 最大并发设为 10，这些性能参数在当前团队规模下提供了合理的资源利用率。随着项目规模增长，这些参数可以根据需要进行调整。

合并请求和代码审查工作流为游戏代码的质量把控提供了制度化的保障。每一次代码变更都通过合并请求提交，经过至少一位团队成员的审查后才能合入主分支。审查者可以在代码的具体行上添加评论，就实现细节展开讨论，并通过"批准"或"请求修改"的机制明确表达审查意见。Issue 跟踪功能则将需求管理、Bug 追踪和任务分配整合在代码仓库的上下文中，让开发者无需在多个工具之间切换就能完成从接受任务到提交代码的完整工作流程。

## 与 Claw Cluster 的协同展望

Claw Cluster（AI 员工集群）作为 EchoThink 平台即将上线的智能核心，将通过 GitLab 丰富的 API 深度参与到游戏代码的开发流程中。Claw Cluster 中的 AI 智能体将具备完整的代码操作能力：它们可以从 GitLab 克隆代码仓库、创建功能分支、在分支上编写和修改代码、提交变更并推送到远程仓库、最终创建合并请求提交人类团队成员审查。整个过程完全通过 GitLab 的 API 以编程方式完成，与人类开发者使用的工作流程完全一致。

更具价值的是 AI 智能体参与代码审查的能力。当人类开发者提交合并请求后，Claw Cluster 中的代码审查 AI 可以自动接收通知、拉取代码变更、分析代码质量和潜在问题，并以评论的形式在合并请求中提出审查意见。反过来，当 AI 智能体提交的合并请求收到人类审查者的修改建议时，AI 智能体能够理解反馈内容，自动修正代码并更新合并请求。这种人机交替审查的模式既提高了代码审查的效率和覆盖率，又保证了人类对最终代码质量的控制权。

在项目管理维度，AI 智能体可以根据 GitLab Issue 中描述的需求自动分解任务、估算工作量，甚至直接开始编码实现。CI/CD 管线的构建结果也会反馈给 AI 智能体——如果自动测试失败，AI 智能体可以分析失败原因并尝试修复。通过 GitLab 这个协作平台，人类团队成员和 AI 智能体以统一的工作流程和沟通界面进行协作，模糊了人机之间的边界，让 AI 真正成为团队中的"数字员工"。这种协作模式将极大地提升游戏开发团队的产能，让人类成员能够将更多精力投入到创造性工作中，而将重复性的编码、测试和审查任务交给 AI 智能体处理。
