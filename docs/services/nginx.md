# Nginx — EchoThink 的统一网关

## 概述

Nginx 是 EchoThink 平台唯一面向外部网络的入口点，承担着反向代理、TLS 终结、子域名路由、WebSocket 升级、gRPC 透传和速率限制等多重职责。所有发往 EchoThink 各服务的 HTTP、HTTPS 和 WebSocket 请求都必须首先经过 Nginx 网关的处理，由它根据请求的目标子域名将流量转发到对应的内部服务。这种统一网关架构意味着除了 Nginx 容器暴露的 80 和 443 端口之外，EchoThink 的所有其他服务都不直接暴露任何端口到宿主机网络上——这是纵深防御策略的第一层实现。

EchoThink 部署的是 `nginx:1.29.5-alpine` 镜像。Nginx 容器的启动过程经过了精心设计，以支持环境变量的动态替换。启动命令是一段 shell 脚本，它首先使用 `envsubst` 工具将主配置文件 `nginx.conf` 和所有站点配置文件 `conf.d/*.conf` 中的 `${DOMAIN}` 占位符替换为实际的域名值，将处理后的配置写入 `/tmp` 目录，然后以处理后的配置文件启动 Nginx。这种模板化方案使得整个平台的域名可以通过一个环境变量 `DOMAIN` 统一配置，部署到不同环境时只需修改 `.env` 文件中的一行配置，所有服务的子域名就会自动更新。

## 双网络架构

Nginx 是 EchoThink 中唯一同时接入两个 Docker 网络的容器。`echothink-internal` 是一个设置了 `internal: true` 属性的桥接网络，这意味着该网络中的容器完全无法与外部世界通信——既不能接收外部请求，也不能发起外部连接。PostgreSQL、Redis、MinIO 以及所有应用服务容器都仅加入这个内部网络，从而在网络层面彻底隔离了敏感服务。`echothink-public` 是一个普通的桥接网络，拥有正常的外部连通性。

Nginx 容器同时加入了这两个网络，因此它既能接收来自外部的 HTTP/HTTPS 请求（通过 `echothink-public` 网络），又能将这些请求转发到内部服务（通过 `echothink-internal` 网络）。这种双网络架构比传统的单网络加防火墙规则的方案更加安全——即使攻击者突破了某个应用服务容器，该容器也无法直接访问互联网来下载恶意工具或传输窃取的数据，因为它所在的 `echothink-internal` 网络根本没有出站路由。

Nginx 容器的启动依赖于 PostgreSQL 和 Redis 的健康检查通过（`condition: service_healthy`），这确保了当 Nginx 开始接受外部请求时，核心的基础设施服务已经就绪，不会出现服务可达但后端未就绪的尴尬情况。

## 子域名路由体系

EchoThink 为每个服务分配了独立的子域名，Nginx 通过 `server_name` 指令将请求路由到对应的 upstream 后端。当前配置了以下十个子域名路由，每个路由对应一个独立的 Nginx 配置文件（位于 `services/nginx/conf.d/` 目录）。

身份认证服务 Authentik 通过 `auth.DOMAIN` 子域名访问，后端为 `authentik-server:9000`。Authentik 的配置中还包含了一个特殊的 `/outpost.goauthentik.io` 位置块，用于处理前向认证（forward auth）请求——其他服务可以通过这个端点验证用户的登录状态。Dify AI 应用平台通过 `dify.DOMAIN` 访问，配置了两个 upstream：`dify-web:3000` 处理前端页面请求，`dify-api:5001` 处理 API 调用，请求根据路径前缀（`/api/`、`/console/api/`、`/v1/`、`/files/`）被路由到不同的后端。LiteLLM 模型网关通过 `litellm.DOMAIN` 访问，后端为 `litellm:4000`，特别地，`/chat/completions` 路径禁用了代理缓冲（`proxy_buffering off`）并设置了 600 秒的读取超时，以支持流式响应（Server-Sent Events）的长连接传输。

Hatchet 任务引擎通过 `hatchet.DOMAIN` 访问，配置了标准的 HTTP 反向代理指向 `hatchet-api:8080`，同时在 `/hatchet/` 路径下配置了 gRPC 透传（`grpc_pass grpc://hatchet-engine:7070`），使得 Hatchet 的 worker 节点可以通过 gRPC 协议与引擎通信。这是 EchoThink Nginx 配置中唯一使用 gRPC 代理的服务，它要求 Nginx 编译时包含 ngx_http_grpc_module 模块（Alpine 官方镜像已默认包含）。

Supabase 通过两个子域名暴露：`studio.DOMAIN` 指向 Supabase Studio 管理界面（`supabase-studio:3000`），`supabase.DOMAIN` 指向 Supabase API 网关（`supabase-kong:8000`）。后者的 `/realtime/` 路径配置了 WebSocket 支持和 86400 秒（24 小时）的读取超时，以维持 Supabase Realtime 的长连接。`/storage/` 路径的 `client_max_body_size` 被提升到 100MB，支持大文件上传。

其余四个服务的子域名配置相对简单。GitLab 通过 `gitlab.DOMAIN` 访问（`gitlab:8929`），`client_max_body_size` 设置为 250MB 以支持大型代码仓库的推送操作。MinIO 通过 `minio.DOMAIN`（控制台）和 `s3.DOMAIN`（S3 API）两个子域名访问，S3 API 端点禁用了代理缓冲并将 `client_max_body_size` 设置为 0（无限制），以支持任意大小的对象上传。n8n 通过 `n8n.DOMAIN` 访问（`n8n:5678`），禁用了分块传输编码和代理缓冲以兼容其 WebSocket 连接。Outline 通过 `outline.DOMAIN` 访问（`outline:3000`），Langfuse 通过 `langfuse.DOMAIN` 访问（`langfuse:3000`）。

所有站点配置都同时监听 80 和 443 端口，SSL 证书统一指向 `/etc/nginx/ssl/server.crt` 和 `/etc/nginx/ssl/server.key`。多个服务的配置中预留了 Authentik 前向认证的 include 指令（目前为注释状态），待 Authentik SSO 完全配置好后取消注释即可为这些服务启用统一的身份验证保护。

## WebSocket 与流式传输支持

现代 Web 应用大量依赖 WebSocket 协议实现实时通信，Nginx 的全局配置中定义了一个 `map` 指令将 `$http_upgrade` 头映射到 `$connection_upgrade` 变量，为所有需要 WebSocket 升级的服务提供统一的头部处理。Dify 的 Web 界面使用 WebSocket 实现对话的实时流式输出，Authentik 使用 WebSocket 推送会话状态变更，n8n 使用 WebSocket 实现工作流编辑器的实时预览，Outline 使用 WebSocket 实现多人协同编辑，Supabase Realtime 更是完全基于 WebSocket 构建的实时数据同步通道。Nginx 在转发这些请求时会自动处理 HTTP 到 WebSocket 的协议升级，对上层应用完全透明。

LiteLLM 的流式 API 端点使用 Server-Sent Events 而非 WebSocket，但同样需要 Nginx 的特殊处理。通过在 `/chat/completions` 路径下禁用 `proxy_buffering` 和 `proxy_cache`，Nginx 不会缓冲后端的响应数据，而是逐字节地将流式 token 转发给客户端，确保用户在前端能看到 AI 模型的逐步生成过程，而非等待整个响应完成后才一次性显示。

## 速率限制与安全加固

Nginx 全局配置中定义了两个速率限制区域（rate limiting zone），为不同类型的请求提供差异化的流量控制。`api` 区域以客户端 IP 为键，允许每秒 30 个请求，适用于一般的 API 调用场景。`auth` 区域更为严格，限制为每秒 10 个请求，专门用于保护认证相关的端点，防止暴力破解攻击。两个区域各分配了 10MB 的共享内存用于存储客户端 IP 的请求计数状态，足以同时追踪约 160,000 个不同的客户端 IP。

安全加固方面，`server_tokens off` 指令隐藏了响应头中的 Nginx 版本信息，避免向攻击者泄露服务器软件版本，降低已知漏洞被利用的风险。全局 `client_max_body_size` 设置为 100MB，各服务可以在自己的配置中覆盖这个默认值。Gzip 压缩默认开启，压缩级别为 6，覆盖了 text、JSON、JavaScript、XML、SVG 等常见内容类型，在不显著增加 CPU 负担的前提下减少网络传输量。

## 高性能调优

Nginx 的工作进程数设置为 `auto`，自动匹配宿主机的 CPU 核心数。每个工作进程的最大文件描述符限制为 65535，最大连接数为 4096，使用 `epoll` 事件模型和 `multi_accept on` 配置，这些是 Linux 系统上高并发场景的最佳实践配置。`sendfile on` 和 `tcp_nopush on` 配合 `tcp_nodelay on` 的组合优化了静态文件传输和小数据包的发送效率。全局的代理设置中，`proxy_http_version 1.1` 确保与后端服务使用 HTTP/1.1 保持连接复用，一系列 `proxy_set_header` 指令将客户端的真实 IP、协议类型、原始主机名等信息透传给后端服务，使后端应用能正确处理日志记录、重定向 URL 生成和安全策略判断。

## 游戏开发中的应用价值

对于游戏设计与开发团队，Nginx 统一网关的价值首先体现在简化了开发环境的配置。团队成员只需记住一个域名和一组子域名前缀，就能访问所有平台服务——`dify.echothink.local` 用于 AI 应用开发，`gitlab.echothink.local` 用于代码管理，`outline.echothink.local` 用于查阅设计文档，`minio.echothink.local` 用于管理游戏资产。所有连接都通过 TLS 加密，即使在内部网络中也保证了数据传输的安全性，这对于保护未公开的游戏设计文档和源代码至关重要。

WebSocket 的统一处理使得团队的实时协作体验更加流畅。多位设计师在 Outline 中同时编辑世界观文档时，Nginx 透明地维护着每个编辑器的 WebSocket 连接。当 Dify 中的 AI 对话正在流式生成游戏剧情文本时，Nginx 确保每一个 token 都能即时到达设计师的浏览器。Supabase Realtime 推送的游戏数据变更通知也通过 Nginx 的 WebSocket 代理传递，让开发者在本地测试环境中就能体验到与生产环境一致的实时数据流。

## Claw Cluster 集成展望

Claw Cluster（AI 员工集群）上线后，Nginx 将成为所有 AI 代理访问 EchoThink 服务的统一入口。每个 AI 代理的 HTTP 请求都将通过 Nginx 网关路由到目标服务，这意味着 Nginx 的访问日志将成为审计 AI 代理行为的重要数据源——通过分析日志中的请求路径、频率和响应状态码，运维团队可以全面了解 Claw Cluster 的工作模式和资源消耗情况。

Nginx 的速率限制机制将在 Claw Cluster 场景中发挥关键的保护作用。当多个 AI 代理同时密集地调用 LiteLLM API 或 Dify API 时，速率限制能防止某个失控的代理耗尽后端服务的处理能力。运维团队可以根据 Claw Cluster 的实际流量模式调整速率限制的阈值，或者为 AI 代理的请求设置独立的限流区域，确保人类用户和 AI 代理的服务体验不会相互影响。

gRPC 透传能力对于 Claw Cluster 与 Hatchet 任务引擎的集成尤为关键。Claw Cluster 中的 AI 代理将作为 Hatchet 的 worker 节点注册，通过 gRPC 协议接收任务分配和上报执行状态。Nginx 在这个通信链路中作为透明的代理层，不干预 gRPC 消息的内容但提供 TLS 加密和负载均衡的能力，确保 AI 代理与任务引擎之间的通信既安全又高效。

## 关键配置速查

- 镜像：`nginx:1.29.5-alpine`
- 容器名称：`echothink-nginx`
- 外部端口：80（HTTP）、443（HTTPS）
- 网络：`echothink-internal` + `echothink-public`（双网络）
- 工作进程：auto（自适应 CPU 核心数）
- 单进程最大连接数：4096
- 速率限制：api 区域 30 req/s，auth 区域 10 req/s
- 全局请求体限制：100MB
- SSL 证书路径：`/etc/nginx/ssl/server.crt`、`/etc/nginx/ssl/server.key`
- 子域名：auth / dify / litellm / hatchet / studio / supabase / gitlab / minio / s3 / n8n / outline / langfuse
