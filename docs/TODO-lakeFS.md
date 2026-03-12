# TODO：在 EchoThink Infra 中引入 lakeFS 以支撑游戏资产版本化

## 1. 背景

当前 EchoThink 的基础设施已经具备以下能力：

- `MinIO` 负责对象存储；
- `GitLab` 负责代码、分支、Merge Request 与 Git LFS；
- `Dify` 与 `n8n` 负责 AI 工作流与自动化编排；
- `Outline` 负责需求与设计文档；
- `ClawCluster` 负责规划、执行、发布与可观测性桥接。

但就“游戏资产版本管理”这一具体问题而言，当前代码库还缺少一个真正的“对象数据版本控制层”。

## 2. 对当前代码库的对比结论

### 2.1 已有内容

1. `GitLab` 已经接入 `MinIO`，但接入方式是 **GitLab 自身对象存储后端**，不是对任意业务 bucket 提供 Git 语义。当前配置可见：
   - `services/gitlab/docker-compose.gitlab.yml`
   - 其中启用了 `gitlab_rails['object_store']`，并将 `gitlab-artifacts`、`gitlab-lfs`、`gitlab-mr-diffs` 等 bucket 交给 MinIO 托管。

2. `MinIO` 当前已经初始化了多个 bucket，但没有任何 `lakeFS` 相关 bucket、前缀或服务：
   - `services/minio/docker-compose.minio.yml`
   - 当前 bucket 包括 `artifacts`、`backups`、`dify-storage`、`outline-data`、`gitlab-lfs` 等。

3. `Dify` 当前已经使用 S3 兼容存储，并且部署了 `plugin-daemon`：
   - `services/dify/docker-compose.dify.yml`
   - 这意味着 Dify 侧已经具备接入自定义工具插件的运行条件。

4. `n8n` 当前是标准部署：
   - `services/n8n/docker-compose.n8n.yml`
   - 目前没有任何 `lakeFS` 专用凭证、节点或连接配置。

5. 现有文档 `docs/workflows/game-asset-pipeline.md` 中，资产流程的结论仍然是：
   - AI 生成资产先进入 MinIO；
   - 人工审核后通过 **GitLab LFS** 纳入版本控制。

### 2.2 当前缺口

上述设计适合“少量二进制素材最终归档到 Git LFS”的场景，但**不适合**下面这种更高频、更接近数据工程的资产工作流：

1. 设计师在 AI Generate 页面反复生成/重生成资产；
2. 每次生成都需要可追溯版本、标签、候选状态与回滚点；
3. 开发者在 Godot 本地通过插件拉取候选资产并验证；
4. 开发者可能要求对同一个逻辑资产继续重生成，而不是只把某个二进制文件提交进 Git 仓库；
5. 本地需要执行 `pull / diff / compare / promote` 一类接近 Git 的动作，但对象源头仍在对象存储中。

**结论：当前 `MinIO + GitLab LFS` 的组合不足以覆盖这个资产版本化需求。**

## 3. 为什么需要 lakeFS

`lakeFS` 的价值不在于替代 GitLab，而在于给对象存储增加 Git-like 语义：

- branch
- commit
- merge
- tag
- revert
- hooks / validation

这类能力非常适合“AI 反复生成 → 人工筛选 → 本地验证 → 批准发布”的素材流水线。

对 EchoThink 的资产场景而言，`lakeFS` 解决的是：

- 资产不是源码，但需要版本控制；
- 资产存储在对象存储而不是 Git repo；
- 需要候选版本、稳定版本、批准版本等语义；
- 需要让 Godot 插件按版本拉取，而不是按裸 bucket path 拉取；
- 需要把“重新生成资产”建模为新版本，而不是覆盖旧对象。

## 4. 建议的职责分工

### 4.1 GitLab 继续负责

- 游戏代码；
- 文本场景/配置文件；
- 与代码审核强绑定的版本记录；
- 可选的 `assets.lock` / `asset-manifest` 文件；
- Merge Request 审核流。

### 4.2 MinIO + lakeFS 负责

- AI 生成的原始资产对象；
- 候选/已批准资产版本；
- 大型二进制资产包；
- 资产版本标签与对象级快照。

### 4.3 需要新增的业务层

除了 `lakeFS` 本身，还需要一个轻量的 **Asset Bridge / Asset Registry**，否则工作流仍然只有“对象路径”，没有“逻辑资产”语义。

这个层至少要负责：

- `asset_id` 管理；
- 逻辑资产到 lakeFS repository/ref 的映射；
- 当前 `candidate` / `approved` / `stable` 指针；
- 导入目标路径、依赖关系、许可证信息；
- 与 Godot 插件、Dify/n8n、ClawCluster 的统一接口；
- 将 promote / rollback / regenerate 请求转成后端动作。

## 5. 建议的资产模型

建议区分以下几个概念：

### 5.1 逻辑资产

示例：

- `asset_id = hero_sword`
- `asset_id = npc_portrait_merchant_01`
- `asset_id = ui_inventory_icon_pack`

### 5.2 不可变版本

每次生成都创建新版本，禁止覆盖旧版本：

- `commit_id`
- 或命名标签 `v2026-03-13-001`

### 5.3 可变通道

用来表达业务状态，而不是实际内容：

- `draft`
- `candidate`
- `approved`
- `stable`
- `deprecated`

**重要原则：不要“更新旧版本”，而要“生成新版本，再移动业务通道”。**

## 6. 目标工作流

## 6.1 设计师 AI Generate 流程

1. 设计师在前端 AI Generate 页面提交素材需求；
2. `n8n` 负责接收前端请求、调度流程、回调与状态编排；
3. `Dify` 负责提示词增强、方案生成、变体生成、审阅辅助；
4. 生成结果先写入 `lakeFS` 的 `draft` / `candidate` 分支或对应提交；
5. `Asset Registry` 记录该次生成与 `asset_id`、项目、风格、来源任务、Prompt、模型参数之间的关系；
6. 页面展示候选结果，设计师可继续筛选、重生成、打标签。

## 6.2 开发者 Godot 拉取流程

1. Godot 插件查询逻辑资产的当前候选版本；
2. 插件查看本地已固定版本与云端候选版本的差异；
3. 插件执行 `pull`，下载指定 ref 对应的资产对象；
4. 本地导入、重导入、场景加载和验证；
5. 若验证通过，可发起 promote 请求；
6. 若验证失败，可把反馈回送 AI Generate 页面，要求基于该资产重生成新版本。

## 6.3 重生成流程

1. 开发者在 AI Generate 页面或 Godot 插件中对某个 `asset_id` 提交反馈；
2. 新一轮生成基于旧版本上下文进行，但仍产出**全新版本**；
3. 原有版本保留，便于比较与回滚；
4. `candidate` 指针更新到新版本；
5. 插件收到变更事件后可再次 `pull`。

## 7. Dify / n8n 能否创建 lakeFS 连接

下面分“代码库现状”和“官方能力推断”两层说明。

### 7.1 当前代码库现状

#### Dify

当前 `Dify` 已经在 `services/dify/docker-compose.dify.yml` 中启用了：

- `PLUGIN_DAEMON_URL`
- `PLUGIN_DAEMON_KEY`
- 独立的 `dify-plugin-daemon`

这说明当前 infra 已经具备：

- 安装 Dify 工具插件；
- 通过内部插件形式扩展第三方系统连接；
- 在工作流中把外部服务封装为工具。

#### n8n

当前 `n8n` 部署中没有 lakeFS 连接配置，也没有自定义节点声明。也就是说：

- 当前代码库里**还没有**可直接复用的 lakeFS 连接器；
- 如果要接入，现阶段需要使用通用节点或新增自定义节点/凭证模板。

### 7.2 基于官方文档的可行性判断

> 以下判断基于官方文档能力推断，不是当前代码库已实现状态。

#### n8n

根据官方文档：

- `n8n` 有通用的 **S3 node**，可连接非 AWS 的 S3 兼容存储；
- `n8n` 有 **HTTP Request node**，可直接调用任意 REST API；
- `lakeFS` 提供 **S3 Gateway API** 与原生版本控制 API。

因此可推断：

1. **对象读写层**：可以通过 `n8n S3 node` 连接 `lakeFS` 的 S3 Gateway；
2. **版本控制层**：branch / commit / merge / tag / compare / revert 更适合通过 `HTTP Request node` 调用 `lakeFS` API；
3. 如果工作流会大量复用这些动作，建议后续开发一个 **n8n 自定义 node** 或内部模板工作流，而不是每个流程都手写 HTTP 请求。

#### Dify

根据官方文档：

- `Dify Workflow` 有 **HTTP Request node**；
- `Dify` 支持 **Tool Plugin**、自定义工具、MCP/插件式扩展；
- 当前 infra 已部署 `plugin-daemon`，所以从运行条件看适合扩展内部工具。

因此可推断：

1. **快速接入**：可先用 `HTTP Request node` 直接调用 `lakeFS` API；
2. **生产方案**：建议做一个内部的 `lakeFS Tool Plugin` 或统一的 `Asset Bridge Tool`；
3. 对“按逻辑资产操作”的生产语义，不建议让每个 Dify 工作流直接拼装底层 lakeFS API，而应经由 `Asset Bridge` 统一封装。

### 7.3 推荐结论

- `n8n` 更适合做 **编排器**：接收前端操作、调度生成、触发 promote、通知插件；
- `Dify` 更适合做 **智能生成与分析器**：Prompt 构建、资产评分、风格变体、反馈理解；
- `lakeFS` 更适合做 **版本化资产平面**；
- `Asset Bridge` 更适合做 **业务语义层**；
- 不建议让 Dify/n8n 直接承载全部 lakeFS 业务语义。

## 8. infra 侧需要新增或修改的内容

## 8.1 服务层

- [ ] 新增 `services/lakefs/` 目录与 `docker-compose.lakefs.yml`
- [ ] 为 `lakeFS` 分配独立数据库（建议 `lakefs` 库）
- [ ] 设计 lakeFS 与现有对象存储的连接方式
- [ ] 决定使用现有 `artifacts` bucket 前缀还是新增专用 bucket（推荐专用，如 `game-assets`）
- [ ] 为 `lakeFS` 增加健康检查
- [ ] 在 `docker-compose.yml` / `docker-compose.apps.yml` 中挂入服务
- [ ] 在 `scripts/healthcheck.sh` 中加入 `lakeFS` 健康检查
- [ ] 在 `scripts/backup.sh` 中补充 `lakeFS` 元数据库与相关对象数据的备份说明
- [ ] 在 `k8s/helm/echothink/templates/` 下预留 lakeFS Chart/Template

## 8.2 网络与边界

- [ ] 决定 `lakeFS` 是否需要对外 UI（例如 `lakefs.${DOMAIN}`）
- [ ] 若需要，对 `nginx` 与公私网络策略做补充
- [ ] 限制只有内部服务和受控客户端可访问 lakeFS API
- [ ] 明确 Godot 插件是否允许直接访问 lakeFS，还是只能走 Editor Gateway / Asset Bridge

## 8.3 资产模型与桥接层

- [ ] 新增 `Asset Registry` / `Asset Bridge` 设计文档
- [ ] 定义 `asset_id`、版本、通道、项目绑定、导入目标路径等模型
- [ ] 定义从 AI 生成结果到逻辑资产的映射
- [ ] 定义 promote / rollback / deprecate / regenerate API
- [ ] 定义与 Supabase/Postgres 的元数据表结构
- [ ] 定义与 ClawCluster 的工作项映射方式

## 8.4 Dify / n8n

- [ ] 为 `AI Generate` 页面设计完整前后端触发链路
- [ ] 在 `n8n` 中实现生成编排、状态推进、回调与通知
- [ ] 评估并实现 `lakeFS` 的 `HTTP Request` 工作流模板
- [ ] 评估并实现 `n8n` 的通用 lakeFS 凭证模板
- [ ] 设计 Dify 资产生成 Workflow 输入/输出规范
- [ ] 评估实现 `Dify lakeFS Tool Plugin`，或统一 `Asset Bridge Tool Plugin`
- [ ] 将生成结果、评分结果、反馈与版本元数据统一落库

## 8.5 文档与现有工作流修订

- [ ] 更新 `docs/workflows/game-asset-pipeline.md`
- [ ] 将“人工审核后通过 GitLab LFS 纳入版本控制”修正为“代码与锁文件进 GitLab，资产对象版本进入 lakeFS”
- [ ] 更新 `docs/services/minio.md`，明确 lakeFS 引入后的职责边界
- [ ] 更新 `docs/services/gitlab.md`，明确 GitLab 不负责 MinIO 对象版本化
- [ ] 更新 Godot 插件文档，补充基于 lakeFS 的资产 pull / diff / promote 设计

## 9. 建议的第一阶段落地顺序

### Phase A：验证

- [ ] 做一个最小 POC：`MinIO + lakeFS + 单个 repo + 单个 asset_id`
- [ ] 验证 branch / commit / tag / merge / diff 是否满足资产工作流
- [ ] 验证 Godot 插件能否稳定按 ref 拉取同一逻辑资产的不同版本
- [ ] 验证 Dify / n8n 调用 lakeFS API 的权限模型与延迟表现

### Phase B：接入

- [ ] 上线 `lakeFS` 服务
- [ ] 新增 `Asset Registry`
- [ ] 接通 `AI Generate` 页面与 n8n/Dify 工作流
- [ ] 接通 Godot 插件的资产拉取与版本查看

### Phase C：治理

- [ ] 增加分支保护、批准流与对象级审计
- [ ] 增加版本保留策略与清理策略
- [ ] 定义“approved/stable”通道的变更门禁
- [ ] 将资产版本与 GitLab 中的 `assets.lock` 建立关联

## 10. 当前建议结论

对 EchoThink 的游戏资产场景，建议采用以下总体方案：

> `MinIO` 继续作为对象存储底座，`lakeFS` 作为对象版本控制层，`GitLab` 继续作为代码与审核层，`Dify/n8n` 负责 AI 生成与流程编排，另增 `Asset Bridge / Asset Registry` 作为业务语义层。

这是比“单纯把资产放进 GitLab LFS”更符合设计师/开发者双流程协作的方案。
