# Authentik — EchoThink 的身份认证与访问治理中心

## 概述与定位

在 EchoThink 这样一个融合了人类团队与 AI 智能体的协作平台中，身份认证与访问控制并不仅仅是一个技术层面的附属功能，而是整个架构赖以运转的信任基石。Authentik 在 EchoThink 中扮演的正是这样一个核心角色：它是所有服务的中央身份提供者（Identity Provider），负责统一管理人类用户和 AI 智能体的身份、认证流程以及跨服务的访问授权。无论团队成员需要登录 Dify 来编排 AI 工作流，还是在 GitLab 上提交游戏代码，又或者在 Outline 知识库中查阅游戏设计文档，他们都只需要通过 Authentik 完成一次认证，即可无缝访问整个平台的所有工具。这种统一登录体验对于一个专注于游戏设计与开发的团队而言至关重要——创意工作需要专注力，频繁在不同工具间切换登录会严重打断思维的连贯性。

Authentik 采用 ghcr.io/goauthentik/server:2026.2.1 镜像部署，运行在 EchoThink 的 Docker Compose 环境中。它依赖共享的 PostgreSQL 数据库（数据库名称为 `authentik`，用户为 `authentik_user`）存储所有身份和配置数据，同时依赖 Redis 来管理会话缓存和异步任务队列。这两个基础设施组件通过健康检查机制确保在 Authentik 启动之前已经完全就绪，从而保证整个认证系统的可靠性。

## 双容器架构

Authentik 在 EchoThink 中以两个容器的形式运行，这种架构分离了请求处理与后台任务处理的职责。第一个容器是 `authentik-server`，它负责处理所有 HTTP 请求，提供认证界面、OAuth2/OIDC 端点以及管理后台。该容器对外暴露 9000（HTTP）和 9443（HTTPS）端口，同时连接到 `echothink-internal` 和 `echothink-public` 两个 Docker 网络——前者用于与其他内部服务通信，后者则通过 Nginx 反向代理对外提供访问。Server 容器配置了完整的健康检查机制，使用 `ak healthcheck` 命令进行自检，检查间隔为 30 秒，启动宽限期为 60 秒，最多允许 5 次重试。

第二个容器是 `authentik-worker`，它以 `worker` 模式运行同一个镜像，专门负责处理异步后台任务，包括 Blueprint 的应用与同步、邮件发送、定时清理任务以及事件日志的处理。Worker 容器额外挂载了宿主机的 Docker socket（`/var/run/docker.sock`），这使得 Authentik 能够在需要时与 Docker 环境进行交互，例如进行容器发现或者嵌入式的 outpost 部署。Worker 只连接 `echothink-internal` 网络，因为它不需要直接对外提供服务。两个容器共享 `authentik-media` 和 `authentik-templates` 这两个持久化卷，前者存储用户头像、图标等媒体文件，后者存储自定义的邮件和页面模板。

## OAuth2/OIDC 统一单点登录

Authentik 作为 EchoThink 的 OAuth2/OIDC 提供者，为平台中的每一个需要用户认证的服务都配置了独立的 Provider 和 Application。目前已经通过 Blueprint 声明式配置了三个核心服务的 OAuth2 集成。Dify 作为 AI 应用开发平台，其 OAuth2 Provider 使用 `dify` 作为 client_id，配置为 confidential 类型的客户端，回调地址指向 `/dify/console/api/oauth/callback`，令牌有效期为 1 小时，授权码有效期为 1 分钟。GitLab 作为源代码管理和 CI/CD 平台，同样配置了独立的 OAuth2 Provider，client_id 为 `gitlab`，回调地址指向 `/gitlab/users/auth/openid_connect/callback`。Outline 知识库的 Provider 配置类似，client_id 为 `outline`，回调地址为 `/outline/auth/oidc.callback`。

每个 Provider 都定义了三个标准的 Scope Mapping：`openid` 返回用户的唯一标识符（UID），`email` 返回用户邮箱及验证状态，`profile` 则返回用户的显示名称、用户名以及所属的组列表。组信息的传递尤为关键——这意味着当一个 AI 智能体通过 OAuth2 登录到 Dify 或 GitLab 时，下游服务可以根据该智能体所属的组（例如 `agents` 组）来决定其权限范围。所有 Provider 均使用 Authentik 的自签名证书进行 JWT 签名，并采用隐式授权同意流程（`default-provider-authorization-implicit-consent`），这意味着已被分配到相应 Application 的用户在首次登录时不需要手动点击"授权"按钮，从而实现真正无感的单点登录体验。

## 默认认证流程

EchoThink 的默认认证流程（slug 为 `echothink-default-authentication-flow`）经过精心设计，在安全性与使用便捷性之间取得了平衡。整个流程由四个按序执行的 Stage 组成。首先是身份识别阶段（Identification Stage），用户可以通过用户名或邮箱进行识别，系统支持大小写不敏感匹配并显示匹配到的用户信息，同时内联了密码验证阶段以减少页面跳转。接下来是密码验证阶段（Password Stage），支持三种后端验证方式：Authentik 内置后端、Token 后端以及 LDAP 后端，允许最多 5 次失败尝试后锁定。第三个阶段是 MFA 验证（Authenticator Validate Stage），支持 TOTP、WebAuthn 和静态恢复码三种多因素认证方式，但采用了 `not_configured_action: skip` 的策略——如果用户尚未配置任何 MFA 设备则自动跳过，同时设置了 8 小时的信任窗口期（`last_auth_threshold: hours=8`），在此期间内的重复登录不会再次要求 MFA 验证。最后是用户登录阶段（User Login Stage），创建有效期为 24 小时的会话，并支持最长 30 天的"记住我"功能。

这个流程的设计充分考虑了游戏开发团队的工作节奏。开发者在一天的工作中可能需要频繁切换各种工具，8 小时的 MFA 信任窗口确保了一次验证即可覆盖大部分工作时段，而 24 小时的会话有效期则保证了次日需要重新认证以维护安全性。

## AI 智能体的身份体系

EchoThink 平台最具创新性的设计之一，是为 AI 智能体建立了完整的身份体系。在 Authentik 中，这通过专门的用户组和服务账户认证流程来实现。系统预定义了四个用户组：`admins`（超级管理员组）、`team-members`（团队成员组，作为 admins 的子组）、`agents`（AI 智能体组）以及 `service-accounts`（服务间通信账户组）。`agents` 组和 `service-accounts` 组在其属性中分别标记了 `type: agent` 和 `type: service`，这使得系统能够在策略层面区分人类用户和非人类实体。

为了保障安全性，AI 智能体和服务账户使用一条与人类用户完全不同的认证流程——`echothink-service-account-authentication`。这条流程与默认流程有几个关键区别：它只允许通过用户名（而非邮箱）进行身份识别，不显示匹配用户信息以防止信息泄露，登录失败阈值更低（3 次即锁定），会话有效期仅为 1 小时且不支持"记住我"功能，并且要求用户处于未认证状态才能发起登录（`require_unauthenticated`）。更重要的是，这条流程绑定了一条表达式策略（Expression Policy），只允许属于 `service-accounts` 或 `agents` 组的用户使用该流程，从而在架构层面隔离了人类认证与机器认证的通道。

## Blueprint 声明式配置体系

Authentik 的 Blueprint 系统是 EchoThink 实现基础设施即代码（Infrastructure as Code）理念的重要组成部分。所有的认证流程、OAuth2 Provider、用户组和策略定义都以 YAML 格式的 Blueprint 文件存储在 `services/authentik/blueprints/` 目录下，并以只读模式挂载到两个容器的 `/blueprints/custom` 路径中。当 Authentik 启动或 Worker 执行同步任务时，这些 Blueprint 会被自动发现并应用。

目前 EchoThink 的 Blueprint 体系包含五个核心文件：`default-auth-flow.yml` 定义了面向人类用户的默认认证流程，`agent-service-accounts.yml` 定义了用户组体系和 AI 智能体的专属认证流程，`dify-provider.yml`、`gitlab-provider.yml` 和 `outline-provider.yml` 则分别定义了各服务的 OAuth2/OIDC 集成配置。这种声明式的方法使得整个身份治理体系可以通过 Git 进行版本控制和代码审查——当需要为新服务添加 SSO 支持时，只需编写一个新的 Blueprint 文件并提交合并请求，团队可以像审查代码一样审查安全配置的变更。

## 游戏开发团队的价值

对于一个专注于游戏设计与开发的团队而言，Authentik 带来的价值远不止"统一登录"这么简单。游戏开发是一个高度跨学科的协作过程，策划需要在 Outline 中撰写设计文档，美术需要通过 Dify 调用 AI 生成概念草图的描述提示词，程序员需要在 GitLab 上提交代码并运行 CI/CD 流水线——所有这些活动都通过 Authentik 的统一身份体系串联在一起，确保每一个操作都有明确的身份归属和审计记录。

更令人期待的是即将上线的 Claw Cluster（AI 员工集群），它将成为 EchoThink 平台的智能核心。Claw Cluster 中的每一个 AI 智能体都将在 Authentik 中拥有自己独立的服务账户，并根据其职能角色获得精细化的权限配置。例如，负责美术概念的 Agent 将获得 Dify 和 Outline 的访问权限但无法触碰代码仓库；负责自动化测试的 Agent 将拥有 GitLab CI/CD 的执行权限但只能访问特定的测试项目；负责剧情撰写的 Agent 将主要与 Outline 知识库交互并通过 LiteLLM 调用高质量语言模型。这种基于角色的细粒度访问控制将通过 Authentik 的组和策略机制实现，确保每个 AI 智能体在被赋予足够能力的同时，也被约束在合理的权限边界之内。

## 关键配置参考

Authentik Server 端口：9000（HTTP）、9443（HTTPS）

核心环境变量：
- `AUTHENTIK_SECRET_KEY` — 加密密钥
- `AUTHENTIK_POSTGRESQL__HOST` — 数据库主机（默认 `postgres`）
- `AUTHENTIK_POSTGRESQL__NAME` — 数据库名称（默认 `authentik`）
- `AUTHENTIK_POSTGRESQL__USER` — 数据库用户（默认 `authentik_user`）
- `AUTHENTIK_DB_PASSWORD` — 数据库密码
- `AUTHENTIK_REDIS__HOST` — Redis 主机（默认 `redis`）
- `AUTHENTIK_BOOTSTRAP_PASSWORD` — 初始管理员密码
- `AUTHENTIK_BOOTSTRAP_EMAIL` — 初始管理员邮箱

持久化卷：
- `authentik-media` — 媒体文件存储
- `authentik-templates` — 自定义模板存储

Blueprint 文件位置：`services/authentik/blueprints/`
