# FRP 公网访问部署

本文档说明如何把本地 EchoThink 栈通过 FRP 暴露到公网，并保持子域名路由、WebSocket和 SSE正常工作。

## 目标拓扑

- 本地机器运行 EchoThink Docker 栈，`nginx` 监听本机 `80/443`
- 本地机器运行 `frpc`
- 公网服务器 `150.158.12.160` 运行 `frps`
- 公网服务器再运行一个边缘 Nginx，监听真正的 `80/443`
- 域名 `*.example.com` 指向 `150.158.12.160`

## 无域名（仅 IP）部署

如果你没有域名，**不要**把 `.env` 里的 `DOMAIN` 改成 `150.158.12.160`。

原因是当前栈依赖 `auth.${DOMAIN}`、`dify.${DOMAIN}` 这类子域名做本地 Nginx 路由，而 `dify.150.158.12.160` 这种地址并不是可直接使用的公网主机名。

无域名场景下，推荐做法是：

- 本地 EchoThink 仍然保持 `DOMAIN=localhost`
- 公网入口改为 `150.158.12.160:不同端口`
- 公网服务器 Nginx 按端口区分服务，再把 `Host` 改写成对应的本地子域名
- 同时把 `X-Forwarded-Host` 保持为公网 `IP:端口`，让应用生成正确外链

建议端口规划：

- `8443` -> Dify
- `7443` -> Langfuse
- `6443` -> n8n
- `3443` -> Outline
- `5443` -> Supabase API
- `5444` -> Supabase Studio
- `2443` -> GitLab
- `4443` -> LiteLLM
- `9444` -> MinIO Console
- `9445` -> MinIO S3 API
- `7444` -> Hatchet

对应 `.env` 示例：

```dotenv
DOMAIN=localhost
SUPABASE_PUBLIC_URL=https://150.158.12.160:5443
SUPABASE_SITE_URL=https://150.158.12.160:5444
LANGFUSE_PUBLIC_URL=https://150.158.12.160:7443
N8N_WEBHOOK_URL=https://150.158.12.160:6443
N8N_EDITOR_BASE_URL=https://150.158.12.160:6443
N8N_HOST=150.158.12.160
N8N_PROTOCOL=https
N8N_SECURE_COOKIE=true
N8N_PROXY_HOPS=1
OUTLINE_URL=https://150.158.12.160:3443
OUTLINE_FORCE_HTTPS=true
DIFY_PUBLIC_URL=https://150.158.12.160:8443
GITLAB_EXTERNAL_URL=https://150.158.12.160:2443
GITLAB_FORWARDED_PROTO=https
GITLAB_FORWARDED_SSL=on
```

公网服务器 Nginx（按端口映射服务）的示例：

```nginx
map $http_upgrade $connection_upgrade {
    default upgrade;
    '' close;
}

map $server_port $route_host {
    9443 auth.localhost;
    8443 dify.localhost;
    7443 langfuse.localhost;
    6443 n8n.localhost;
    3443 outline.localhost;
    5443 supabase.localhost;
    5444 studio.localhost;
    2443 gitlab.localhost;
    4443 litellm.localhost;
    9444 minio.localhost;
    9445 s3.localhost;
    7444 hatchet.localhost;
}

server {
    listen 9443 ssl http2;
    listen 8443 ssl http2;
    listen 7443 ssl http2;
    listen 6443 ssl http2;
    listen 3443 ssl http2;
    listen 5443 ssl http2;
    listen 5444 ssl http2;
    listen 2443 ssl http2;
    listen 4443 ssl http2;
    listen 9444 ssl http2;
    listen 9445 ssl http2;
    listen 7444 ssl http2;
    server_name 150.158.12.160;

    ssl_certificate /etc/nginx/ssl/ip.crt;
    ssl_certificate_key /etc/nginx/ssl/ip.key;

    location / {
        proxy_pass https://127.0.0.1:10443;
        proxy_ssl_server_name on;
        proxy_ssl_verify off;

        proxy_http_version 1.1;
        proxy_set_header Host $route_host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Port $server_port;
        proxy_set_header X-Forwarded-Host $host:$server_port;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_read_timeout 86400;
        proxy_send_timeout 86400;
    }
}
```

注意：如果你想让浏览器对 `https://150.158.12.160:端口` 不报证书警告，Let’s Encrypt 已在 **2026 年 1 月 15 日** 正式提供 IP 地址证书，但它们是 **约 6 天有效期** 的 short-lived 证书，且 ACME 客户端需要支持该能力。

## 1. 本地 `frpc.toml`

你当前的配置可以继续使用：

```toml
serverAddr = "150.158.12.160"
serverPort = 7000

[auth]
method = "token"
token = "REPLACE_ME"

[[proxies]]
name = "ssh"
type = "tcp"
localIP = "127.0.0.1"
localPort = 22
remotePort = 6000

[[proxies]]
name = "echothink-http"
type = "tcp"
localIP = "127.0.0.1"
localPort = 80
remotePort = 10080

[[proxies]]
name = "echothink-https"
type = "tcp"
localIP = "127.0.0.1"
localPort = 443
remotePort = 10443
```

## 2. 公网服务器 `frps.toml`

```toml
bindPort = 7000

[auth]
method = "token"
token = "REPLACE_ME"

allowPorts = [
  { single = 6000 },
  { single = 10080 },
  { single = 10443 },
]
```

## 3. 公网服务器 Nginx

在 `150.158.12.160` 上让 Nginx 接收公网请求，再反向代理到 FRP 暴露出来的 `10080/10443`。

示例：

```nginx
map $http_upgrade $connection_upgrade {
    default upgrade;
    '' close;
}

server {
    listen 80;
    server_name auth.example.com dify.example.com litellm.example.com hatchet.example.com \
                studio.example.com supabase.example.com gitlab.example.com minio.example.com \
                s3.example.com n8n.example.com outline.example.com langfuse.example.com;

    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    server_name auth.example.com dify.example.com litellm.example.com hatchet.example.com \
                studio.example.com supabase.example.com gitlab.example.com minio.example.com \
                s3.example.com n8n.example.com outline.example.com langfuse.example.com;

    ssl_certificate /etc/letsencrypt/live/example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/example.com/privkey.pem;

    location / {
        proxy_pass https://127.0.0.1:10443;
        proxy_ssl_server_name on;
        proxy_ssl_verify off;

        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Port 443;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_read_timeout 86400;
        proxy_send_timeout 86400;
    }
}
```

如果你更喜欢明文回源，也可以把 `proxy_pass` 改成 `http://127.0.0.1:10080`。本仓库里的本地 Nginx 已经保留上游传入的 `X-Forwarded-Proto`，所以应用仍然会识别公网 HTTPS。

## 4. 本仓库 `.env` 需要设置的关键项

把 `.env` 中这些值改成你的真实域名：

```dotenv
DOMAIN=example.com
SUPABASE_PUBLIC_URL=https://supabase.example.com
SUPABASE_SITE_URL=https://studio.example.com
LANGFUSE_PUBLIC_URL=https://langfuse.example.com
N8N_WEBHOOK_URL=https://n8n.example.com
N8N_EDITOR_BASE_URL=https://n8n.example.com
N8N_PROTOCOL=https
N8N_SECURE_COOKIE=true
OUTLINE_URL=https://outline.example.com
OUTLINE_FORCE_HTTPS=true
DIFY_PUBLIC_URL=https://dify.example.com
GITLAB_EXTERNAL_URL=https://gitlab.example.com
GITLAB_FORWARDED_PROTO=https
GITLAB_FORWARDED_SSL=on
```

## 5. 重启

完成修改后重启：

```bash
docker compose -f docker-compose.yml -f docker-compose.apps.yml up -d
```

## 6. 注意事项

- 需要把 DNS 记录指向 `150.158.12.160`
- 需要在公网服务器安全组和防火墙放行 `80/443/7000`
- GitLab 主站已经可通过 `gitlab.${DOMAIN}` 访问；容器镜像仓库 `registry.${DOMAIN}` 仍需单独加一个本地 Nginx vhost
