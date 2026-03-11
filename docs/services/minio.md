# MinIO — EchoThink 的对象存储服务

## 概述

MinIO 为 EchoThink 平台提供了完全兼容 Amazon S3 API 的对象存储服务。在游戏设计与 AI 协作的工作流中，大量非结构化数据——纹理贴图、3D 模型文件、音频素材、概念艺术图片、AI 生成的内容、构建产物等——需要一个可靠且高性能的存储系统。MinIO 正是为此而存在的。它以 `minio/minio:RELEASE.2025-09-07T16-13-09Z-cpuv1` 镜像运行，通过 `server /data --console-address ":9001"` 命令同时启动 S3 API 服务和 Web 管理控制台。API 端口为 9000，控制台端口为 9001，两个端口均通过 Nginx 反向代理对外暴露，分别映射到 `s3.DOMAIN` 和 `minio.DOMAIN` 子域名。

与 PostgreSQL 和 Redis 一样，MinIO 容器仅接入 `echothink-internal` 内部网络，所有外部访问都必须经由 Nginx 网关。数据存储在 Docker 命名卷 `minio-data` 中，确保容器重启或升级时数据不会丢失。健康检查使用 `mc ready local` 命令，每 10 秒执行一次，启动等待期为 10 秒——MinIO 的启动速度很快，不需要像 PostgreSQL 那样长的预热时间。

## 存储桶初始化架构

EchoThink 采用了一个独立的初始化容器 `echothink-minio-init` 来管理存储桶的创建。这个容器基于 MinIO 官方客户端镜像 `minio/mc:RELEASE.2025-08-13T08-35-41Z`，在 MinIO 主服务通过健康检查后自动启动，执行一系列存储桶创建命令后退出。这种 sidecar 初始化模式的优势在于它将存储桶的声明式配置与 MinIO 服务的运行时行为分离——运维人员只需修改初始化脚本就能管理存储桶，而不需要登录 MinIO 控制台手动操作。所有 `mc mb` 命令都使用了 `--ignore-existing` 标志，确保脚本可以在任何状态下幂等执行，无论是首次部署还是容器重启后的重新初始化。

初始化脚本创建了 15 个存储桶，覆盖了平台中所有需要对象存储的服务。这些存储桶可以按功能分为四个类别。

第一类是平台核心服务存储桶。`supabase-storage` 存储 Supabase 管理的用户上传文件和应用资产，是唯一一个设置了公开匿名下载权限的存储桶（通过 `mc anonymous set download` 命令），因为 Supabase Storage 需要直接向前端客户端提供文件下载服务。`dify-storage` 存储 Dify 平台的知识库文档、用户上传的文件以及 AI 对话中产生的附件。`outline-data` 存储 Outline 知识维基中的图片、附件和导出文件。

第二类是 GitLab 相关的存储桶，共七个。`gitlab-artifacts` 存储 CI/CD 流水线的构建产物，`gitlab-uploads` 存储通过 GitLab 界面上传的文件（如议题附件、评论图片），`gitlab-lfs` 存储 Git LFS（大文件存储）追踪的二进制资产，`gitlab-mr-diffs` 缓存合并请求的差异数据，`gitlab-packages` 存储 GitLab Package Registry 中的软件包，`gitlab-dependency-proxy` 缓存外部容器镜像注册表的代理数据，`gitlab-terraform-state` 存储 Terraform 状态文件，`gitlab-pages` 存储 GitLab Pages 的静态站点内容。GitLab 是所有服务中对对象存储使用最广泛的——将这些数据从 GitLab 的本地文件系统迁移到 MinIO 不仅释放了 GitLab 容器的磁盘压力，还使得这些数据可以通过 S3 API 被其他系统访问和管理。

第三类是 Langfuse 的可观测性数据桶。`langfuse-events` 存储 AI 调用的原始事件数据，`langfuse-media` 存储追踪过程中关联的媒体文件（如音频转录的原始录音文件）。将大量的可观测性数据写入对象存储而非数据库，可以显著降低 PostgreSQL 的存储和 I/O 压力。

第四类是通用运维桶。`artifacts` 作为通用的产物存储桶，可以用于存放各类构建输出、导出数据和临时文件。`backups` 存储 EchoThink 平台的自动备份数据——PostgreSQL 的逻辑备份、配置文件快照和服务状态数据都定期写入这个桶，为灾难恢复提供最后一道防线。

## 游戏开发中的应用价值

对于游戏开发团队而言，MinIO 的价值远不止于简单的文件存储。游戏开发产生的数字资产种类繁多、体量巨大——一个中等规模的游戏项目可能包含数千张纹理贴图（每张从几百 KB 到数十 MB 不等）、数百个 3D 模型文件、数百段音频素材，再加上概念艺术、UI 设计稿、动画文件和各种配置数据。这些资产需要一个既能高效存取又能方便管理的存储系统。

MinIO 的 S3 兼容 API 意味着团队可以使用所有成熟的 S3 生态工具来管理游戏资产。通过 `s3.DOMAIN` 子域名，开发人员可以使用 AWS CLI、rclone 或任何支持 S3 协议的工具直接上传和下载资产。GitLab CI/CD 流水线可以将构建产物——编译好的游戏可执行文件、打包好的资源包、自动化测试报告——自动上传到 `gitlab-artifacts` 桶中，团队成员随时可以下载任何历史版本的构建产物进行测试。

Dify 平台上构建的 AI 资产生成工作流是 MinIO 的另一个重要使用场景。当 AI 模型生成了新的概念艺术图片、角色描述文本或游戏剧情脚本时，这些生成物通过 Dify 的文件管理系统自动存入 `dify-storage` 桶。设计师可以在 Dify 界面中预览和筛选这些 AI 生成的内容，选中满意的资产后将其移入正式的游戏资产管线。Outline 知识维基中引用的设计图片和参考资料同样存储在 MinIO 中，通过 `outline-data` 桶为团队的知识管理提供持久化的文件后端。

备份策略方面，MinIO 的 `backups` 桶与 `scripts/backup.sh` 脚本配合使用，定期将 PostgreSQL 的 pg_dump 输出、各服务的配置快照和关键数据存档到对象存储中。由于 MinIO 支持版本控制和生命周期策略，团队可以设置备份数据的自动过期和清理规则，避免存储空间的无限增长。

## Claw Cluster 集成展望

Claw Cluster（AI 员工集群）将成为 MinIO 最活跃的使用者之一。AI 代理在执行游戏设计任务时需要同时进行大量的读取和写入操作——读取已有的参考资料和游戏资产以理解项目上下文，写入新生成的内容和工作中间产物。MinIO 的 S3 API 为 AI 代理提供了标准化的文件访问接口，使得代理程序可以像使用本地文件系统一样方便地操作对象存储。

在典型的工作流中，一个负责角色设计的 AI 代理会先从 `dify-storage` 或 `outline-data` 桶中读取已有的角色设定文档和视觉参考图片，然后根据这些参考生成新的角色概念设计。生成的文本描述和配套的提示词会写回 `dify-storage`，而如果工作流触发了图像生成模型，生成的图片也会通过 Supabase Storage 写入 `supabase-storage` 桶。整个过程中，Langfuse 会将每一次 AI 调用的详细追踪数据写入 `langfuse-events` 桶，确保所有 AI 代理的行为都是可审计和可回溯的。

Claw Cluster 还将利用 `artifacts` 桶作为 AI 代理之间共享中间结果的工作区。例如，在一个复杂的关卡设计任务中，负责叙事设计的 AI 代理可以将生成的剧情大纲写入 `artifacts` 桶中的一个约定路径，负责关卡布局的 AI 代理则可以从该路径读取剧情要求并据此设计关卡结构。这种基于共享存储的协作模式简单可靠，不需要复杂的消息传递机制即可实现多代理之间的信息共享。

## 关键配置速查

- 镜像：`minio/minio:RELEASE.2025-09-07T16-13-09Z-cpuv1`
- 容器名称：`echothink-minio`
- S3 API 端口：9000
- 控制台端口：9001
- 外部子域名：`minio.DOMAIN`（控制台）/ `s3.DOMAIN`（API）
- 初始化容器：`echothink-minio-init`（基于 `minio/mc`）
- 存储桶数量：15 个
- 数据卷：`minio-data`
- 网络：`echothink-internal`
- 环境变量：`MINIO_ROOT_USER`、`MINIO_ROOT_PASSWORD`
