# ClawCluster Design (HiClaw-Based)

## 1. Purpose

ClawCluster is the agent workforce and execution control plane for EchoThink.

The implementation decision is now explicit:

- ClawCluster will be built on top of **HiClaw** from the Higress team.
- **HiClaw** provides the base multi-agent collaboration architecture.
- **OpenClaw** remains the default agent runtime inside the HiClaw Manager and Worker roles.
- EchoThink remains the broader collaboration substrate and system of record.

This document updates the ClawCluster design to reflect that decision.

The target operating model remains:

- Humans work primarily in Outline, with GitLab used for code review and merge control.
- Existing EchoThink services remain the collaboration substrate and system of record.
- ClawCluster runs in an independent cluster as the execution plane.
- HiClaw provides the team runtime, communication model, and agent security pattern.
- OpenClaw provides the per-agent reasoning and skill execution loop inside HiClaw.

## 2. Decision Summary

ClawCluster is no longer defined as a wholly custom agent control plane.

Instead, the recommended implementation is:

> `ClawCluster = HiClaw team architecture + OpenClaw agent runtime + EchoThink integration bridges + policy and publication layer`

This means:

- we adopt HiClaw’s **Manager + Workers** topology;
- we adopt HiClaw’s **Matrix-based human-visible communication model**;
- we adopt HiClaw’s **Higress AI Gateway** pattern for agent-facing credential brokerage and MCP exposure;
- we adopt HiClaw’s **shared file system** pattern backed by MinIO-compatible object storage;
- we keep EchoThink’s existing systems for structured task state, approval state, code review, knowledge, and observability.

## 3. Reference HiClaw Architecture

Based on the official HiClaw introduction, deployment guide, GitHub README, and architecture document, HiClaw’s reference architecture has the following core characteristics:

### 3.1 Manager–Worker Topology

HiClaw is an Agent Teams system with a clear two-tier structure:

- one **Manager Agent** coordinates the team;
- multiple **Worker Agents** perform specialized work;
- the Manager creates and destroys Workers conversationally;
- the Manager assigns tasks, tracks progress, manages permissions, and performs heartbeats;
- Workers are lightweight and can be restarted or recreated without losing persistent task context.

### 3.2 Matrix as the Communication Bus

HiClaw uses the Matrix protocol as the default human-agent and agent-agent communication layer:

- all significant collaboration happens in Matrix rooms;
- each room can include the human, the Manager, and one or more Workers;
- humans can observe and intervene at any time;
- communication is visible, auditable, and interruptible by design.

### 3.3 Higress as the Agent Gateway

HiClaw places Higress in front of AI and tool access:

- Higress acts as the unified external entry point;
- Higress fronts LLM access and MCP server access;
- Workers do not hold upstream provider secrets directly;
- each Worker uses its own Higress consumer token;
- real external credentials stay in gateway or MCP configuration, not inside Worker containers.

### 3.4 Shared File System via MinIO

HiClaw uses MinIO-compatible object storage as a shared file system:

- Worker configuration is centrally stored;
- task specs and results are stored in shared paths;
- Workers can pull configuration and task context on startup;
- local and remote directories can be mirrored in near real time.

### 3.5 OpenClaw as the Default Agent Runtime

HiClaw is not a replacement for OpenClaw; it is a multi-agent operating model around OpenClaw.

In the reference system:

- the Manager runs as an OpenClaw-powered agent;
- Workers run as OpenClaw-powered agents by default;
- HiClaw adds the team structure, communication model, gateway pattern, and operational scaffolding around them.

### 3.6 Optional Coding CLI Delegation

HiClaw also supports a useful coding pattern:

- Workers can delegate coding tasks to a coding CLI such as Claude Code or Gemini CLI;
- the Manager can run the CLI inside its own workspace and relay results back;
- this provides a pragmatic path for code-heavy tasks without giving each Worker unrestricted local host privileges.

## 4. EchoThink Adaptation of HiClaw

HiClaw is the base architecture, but ClawCluster must still fit EchoThink’s existing systems and operating philosophy.

This section describes the EchoThink-specific adaptation. The mapping here is a design inference on top of the official HiClaw architecture.

### 4.1 Human Surface: Outline First, Matrix Second

HiClaw assumes Matrix is a primary interaction surface. EchoThink should adapt that model rather than copy it literally.

Recommended policy:

- **Outline remains the primary day-to-day human workspace** for specs, plans, reviews, and project documentation.
- **Matrix becomes the operational supervision bus** for agent escalation, intervention, progress visibility, and exception handling.
- Humans should not need to live in Element Web all day.
- However, when a task is risky, blocked, or ambiguous, the relevant Matrix room becomes the live intervention channel.

This preserves the user experience you want while still gaining HiClaw’s human-in-the-loop strengths.

### 4.2 EchoThink Remains the System of Record

HiClaw should not replace EchoThink’s authoritative systems.

Authoritative ownership should remain:

- Outline for long-form project intent and documentation;
- GitLab for code, branches, Merge Requests, and review history;
- Supabase/Postgres for structured task and approval state;
- Hatchet for durable infra-side workflow triggering and long-running task records;
- Graphiti for temporal knowledge and cross-document context;
- Langfuse for LLM traces and cost analytics;
- MinIO for persistent artifacts and shared task filesystem data.

### 4.3 Recommended Gateway Chain

EchoThink already uses LiteLLM as the main LLM gateway. HiClaw introduces Higress as an agent-facing gateway.

Recommended v1 routing pattern:

> `Worker / Manager -> Higress -> LiteLLM -> model providers`

Rationale:

- Higress preserves the HiClaw security model and MCP exposure pattern;
- LiteLLM remains the central model routing, fallback, caching, and cost-control layer for EchoThink;
- Langfuse visibility can continue to piggyback on the current LiteLLM-centered architecture.

This is an EchoThink-specific design choice rather than an official HiClaw requirement.

### 4.4 Recommended Shared Storage Pattern

HiClaw expects a MinIO-compatible shared file system. EchoThink already has MinIO.

Recommended v1 approach:

- do **not** introduce a second long-lived object storage system unless required;
- use the existing EchoThink MinIO service with a dedicated bucket or prefix for HiClaw shared state;
- keep HiClaw’s file layout conventions, but back them with EchoThink-managed object storage.

Recommended bucket or prefix examples:

- `hiclaw-storage/agents/...`
- `hiclaw-storage/shared/tasks/...`
- `hiclaw-storage/shared/knowledge/...`

## 5. Top-Level Placement in EchoThink

ClawCluster should still run in a separate cluster from the current infra cluster.

The difference now is that the separate cluster is no longer an abstract custom execution plane. It is a **HiClaw-based execution and coordination cluster**.

```text
+---------------------------------------------------------------+
|                    EchoThink Infra Cluster                    |
|---------------------------------------------------------------|
| Outline | GitLab | Supabase | Hatchet | Graphiti | LiteLLM    |
| Langfuse | Dify | n8n | MinIO | Nginx                         |
+-----------------------------+---------------------------------+
                              |
                    private ingress / VPN / mTLS
                              |
+---------------------------------------------------------------+
|                ClawCluster (HiClaw-Based) Cluster             |
|---------------------------------------------------------------|
| Higress Gateway | Tuwunel Matrix | Element Web                |
| HiClaw Manager (OpenClaw) | Worker Containers (OpenClaw)      |
| Shared FS sync layer | Optional manager-hosted coding CLI     |
+---------------------------------------------------------------+
                              |
                     Humans intervene when needed
                 via Outline-first workflow + Matrix rooms
```

## 6. Design Principles

The v1 design should follow these principles:

1. **HiClaw-native team structure.** Start with Manager + Workers, not a custom free-form mesh.
2. **Outline-first human workflow.** Human project work stays centered in Outline even though HiClaw uses Matrix operationally.
3. **Gateway-enforced least privilege.** Workers should hold consumer tokens, not upstream secrets.
4. **Stateless Workers where possible.** Worker containers should remain replaceable and restartable.
5. **Structured work over chat-only coordination.** Human prose may originate in Outline, but execution should normalize into typed work items.
6. **Evidence-first publication.** Results should only be published after producing reviewable artifacts, summaries, and trace links.
7. **Human approval for irreversible actions.** Drafting can be autonomous; production-impacting writes must be governed.
8. **Reuse EchoThink systems of record.** ClawCluster should not fork task state, knowledge state, code state, or observability state into a disconnected island.

## 7. Primary Workload Classes

ClawCluster v1 should explicitly support the three workload families already identified for EchoThink.

| Workload | Typical inputs | Typical outputs | Primary systems |
|----------|----------------|-----------------|-----------------|
| Workflow authoring | Outline brief, schema spec, trigger description | Dify workflow draft, n8n workflow draft, JSON schemas, generated artifacts | Dify, n8n, Outline, MinIO |
| Coding | Outline spec, GitLab issue, repo context, acceptance criteria | branch, commits, MR, patch notes, test report | GitLab, Outline, MinIO |
| Planning / documentation | Outline docs, project status, graph context | task breakdowns, ADR drafts, summaries, brainstorm options | Outline, Supabase, Graphiti |

These workload classes should be first-class task types in EchoThink state, while HiClaw handles the execution collaboration pattern.

## 8. Component Model

The ClawCluster component model should now be expressed in two layers: EchoThink-side bridges and HiClaw-native runtime components.

### 8.1 EchoThink-Side Bridges

| Component | Responsibility |
|-----------|----------------|
| Intake Bridge | Converts Outline and GitLab events into structured work items |
| Policy / Approval Bridge | Maps EchoThink approval rules onto HiClaw task publication rules |
| Publisher Bridge | Writes approved outputs back into Outline, GitLab, Dify, n8n, Graphiti, and MinIO |
| Observability Bridge | Links work item ids, Matrix rooms, traces, artifacts, and graph episodes |

### 8.2 HiClaw-Native Runtime Components

| Component | Responsibility |
|-----------|----------------|
| Higress Gateway | Agent-facing gateway for LLM and MCP access, credential brokerage, route policy |
| Tuwunel Matrix | Team communication bus for humans, Manager, and Workers |
| Element Web | Operational supervision UI |
| HiClaw Manager | Team coordinator, Worker lifecycle owner, planner, router, heartbeat operator |
| Worker Containers | Specialized execution actors for planning, workflow building, coding, review, and knowledge tasks |
| Shared FS Layer | Shared task specs, configs, artifacts, and result handoff paths |
| Manager Workspace | Host-mounted Manager context, memory, registry, and optional coding CLI execution area |

## 9. Component Responsibilities in EchoThink

### 9.1 Intake Bridge

The intake bridge should remain an EchoThink responsibility.

Recommended v1 triggers:

- Outline webhook events via n8n;
- GitLab issue and Merge Request webhooks via n8n;
- explicit manual “create work item” actions backed by Supabase.

The intake bridge should convert source material into a canonical `work_item` and then notify the HiClaw Manager.

### 9.2 HiClaw Manager

In the HiClaw-based ClawCluster, the Manager becomes the practical center of control.

The Manager should:

- receive work notifications from EchoThink bridges;
- inspect the canonical work item and supporting artifacts;
- create or select the appropriate Worker;
- create or reuse the appropriate Matrix room;
- stage task specs into shared storage;
- decompose tasks when multiple Workers are needed;
- run heartbeats and escalation logic;
- request human input in Matrix when policy or ambiguity requires it;
- hand off results to the publisher bridge for approved external writes.

### 9.3 Workers

Workers should remain narrowly specialized.

Recommended initial Worker roles:

- `planner-worker`
- `workflow-worker`
- `coding-worker`
- `qa-worker`
- `knowledge-worker`

Each Worker:

- runs as a stateless container when possible;
- receives configuration from shared storage;
- communicates in Matrix rooms;
- uses Higress-issued access for LLM and MCP calls;
- writes results and artifacts to shared storage and the room history.

### 9.4 Higress Gateway

In the HiClaw-based design, Higress is not optional. It is a core architectural decision.

Higress should be used for:

- per-Worker consumer authentication;
- MCP exposure for GitHub and future tools;
- LLM access routing for Manager and Workers;
- rate limiting and route policy by Worker identity;
- keeping real external credentials out of Worker containers.

### 9.5 Matrix Layer

Matrix should be treated as the **team operation plane**, not necessarily the primary project documentation plane.

Its roles are:

- visible delegation from Manager to Worker;
- visible progress updates and blocking questions;
- real-time human intervention;
- escalation channel when tasks require immediate judgment.

### 9.6 Shared File System Layer

HiClaw relies on shared filesystem semantics. In EchoThink, the shared FS should be expressed via MinIO-backed object storage conventions.

Recommended v1 layout:

```text
hiclaw-storage/
  agents/
    <worker-name>/
      SOUL.md
      openclaw.json
      skills/
      mcporter-servers.json
  shared/
    tasks/
      task-<id>/
        meta.json
        spec.md
        base/
        result.md
        artifacts/
    knowledge/
```

This layout is adapted from the official HiClaw architecture and mapped to EchoThink storage.

## 10. System of Record and Data Ownership

ClawCluster should still be execution-oriented rather than state-authoritative.

| State domain | Authoritative system |
|--------------|----------------------|
| Long-form project intent and docs | Outline |
| Structured work items and approval state | Supabase/Postgres |
| Durable infra-side workflow records | Hatchet |
| Team communication history and operational escalation | Matrix / HiClaw |
| Source code and reviews | GitLab |
| Shared task files and artifacts | MinIO |
| Temporal knowledge | Graphiti |
| LLM traces and cost | Langfuse |
| Agent-facing LLM/MCP gateway policy | Higress |

A practical rule:

- if the state is about **project truth**, keep it in EchoThink systems of record;
- if the state is about **agent team operation**, keep it in HiClaw runtime state plus shared storage;
- if the state matters for cross-system reporting, mirror the key identifiers into Supabase.

## 11. Canonical Data Model

Even with HiClaw as the team runtime, EchoThink still needs structured tables for reporting, policy, and integration.

Create a dedicated `clawcluster` schema in the Supabase-backed PostgreSQL instance.

### 11.1 Required v1 Entities

| Entity | Required fields | Purpose |
|--------|------------------|---------|
| `agent_profiles` | `id`, `name`, `role`, `default_worker_type`, `enabled`, `approval_class` | Declares logical roles used by HiClaw |
| `skill_definitions` | `id`, `name`, `version`, `category`, `runtime_class`, `input_schema`, `output_schema` | Versioned skill contracts |
| `agent_skill_bindings` | `agent_profile_id`, `skill_definition_id`, `priority`, `enabled` | Maps roles to skills |
| `work_items` | `id`, `workspace_id`, `kind`, `source_type`, `source_ref`, `objective`, `status`, `priority`, `risk_level`, `approval_policy` | Canonical work request |
| `task_runs` | `id`, `work_item_id`, `agent_profile_id`, `status`, `started_at`, `ended_at`, `langfuse_trace_id`, `cost_usd` | Execution record |
| `approvals` | `id`, `work_item_id`, `gate_name`, `requested_from`, `decision`, `decided_at`, `evidence_json` | Approval tracking |
| `artifacts` | `id`, `task_run_id`, `kind`, `uri`, `checksum`, `metadata_json` | Artifact references |
| `hiclaw_workers` | `id`, `worker_name`, `agent_profile_id`, `matrix_user_id`, `matrix_room_id`, `higress_consumer_id`, `storage_prefix`, `runtime`, `status` | Mirrors the operational HiClaw Worker inventory |
| `external_refs` | `work_item_id`, `outline_doc_id`, `gitlab_project_id`, `gitlab_mr_iid`, `dify_workflow_id`, `n8n_workflow_id`, `matrix_room_id` | Links work items across systems |
| `budget_policies` | `scope_type`, `scope_id`, `daily_cost_limit_usd`, `token_limit`, `concurrency_limit` | Enforces budgets |

### 11.2 Canonical Work Item Shape

All intake paths should normalize to a structure equivalent to:

```json
{
  "id": "wi_01J...",
  "workspace_id": "game-studio-main",
  "kind": "code.implement",
  "source": {
    "type": "outline_document",
    "ref": "doc_abc123"
  },
  "objective": "Implement inventory filtering in the Godot prototype.",
  "acceptance_criteria": [
    "Filter by rarity and item type.",
    "Preserve controller navigation.",
    "Add a minimal regression test or test note."
  ],
  "constraints": {
    "gitlab_project": "games/prototype",
    "base_branch": "main",
    "max_cost_usd": 6.0,
    "max_duration_sec": 5400
  },
  "approval_policy": "medium",
  "requested_by": "user_123"
}
```

The Manager may reason from the source document, but operational execution should always use the normalized object.

## 12. Skill Model

HiClaw gives the team architecture; skills still define what a Worker can actually do.

Skills should remain executable contracts rather than loose prompt bundles.

Each skill should declare:

- required inputs;
- produced outputs;
- required tools;
- whether it is intended for a Worker container or Manager-hosted CLI delegation;
- required MCP services;
- expected publication targets;
- approval class;
- validation requirements.

### 12.1 Skill Manifest Shape

```yaml
apiVersion: clawcluster/v1
kind: Skill
metadata:
  name: code.repo.implement
  version: 0.1.0
spec:
  category: code
  runtimeClass: manager-cli
  description: Implement a bounded code change via HiClaw coding workflow.
  inputs:
    - work_item
    - repo_ref
    - acceptance_criteria
  outputs:
    - patch_summary
    - branch_ref
    - merge_request_ref
    - test_report
  tools:
    - matrix.room
    - gitlab.api
    - outline.read
    - graphiti.search
    - higress.llm
    - higress.mcp.github
    - coding.cli
  guardrails:
    approvalClass: medium
    maxDurationSec: 5400
    maxCostUsd: 6.0
    requiresValidation:
      - tests
      - reviewer_agent
  publishes:
    - gitlab.merge_request
    - outline.summary
```

### 12.2 Initial Skill Families

Recommended initial families:

- `doc.outline.read`
- `doc.outline.write_draft`
- `plan.breakdown`
- `plan.status_summarize`
- `graph.search`
- `graph.sync_episode`
- `workflow.dify.build`
- `workflow.n8n.build`
- `workflow.publish_draft`
- `code.repo.implement`
- `code.repo.review`
- `code.repo.fix_from_review`
- `qa.run_validation`

## 13. Agent Model

In a HiClaw-based system, “agent” means both a logical role and an operational runtime identity.

### 13.1 Logical Roles

| Role | Responsibility |
|------|----------------|
| `manager` | overall coordination, Worker lifecycle, escalation, supervision |
| `planner-worker` | plans, breakdowns, summaries, task tracking |
| `workflow-worker` | Dify and n8n workflow drafting |
| `coding-worker` | repo change planning and coding execution coordination |
| `qa-worker` | validation, review, checks, test interpretation |
| `knowledge-worker` | Graphiti sync, conflict detection, context enrichment |

### 13.2 Recommended v1 Topology

ClawCluster should start with HiClaw’s clear hierarchy rather than an open mesh.

Recommended v1 topology:

- one Manager per workspace or operating domain;
- Workers created on demand or kept warm by specialization;
- one Matrix room per major work item or per specialist thread;
- human members added only where supervision or intervention is needed;
- no hidden Worker-to-Worker side channels outside approved rooms and storage paths.

### 13.3 Worker Lifecycle

ClawCluster should follow HiClaw’s Worker lifecycle pattern:

- Manager creates Worker identity and grants route permissions;
- Worker pulls config from shared storage;
- Worker joins or is associated with the appropriate Matrix room;
- Worker executes the task;
- Manager observes heartbeat and idleness;
- idle Worker may be stopped and later recreated;
- persistent task context stays in storage and room history, not in the container.

## 14. Execution Environments

The execution environment model changes slightly when adopting HiClaw.

### 14.1 Worker Container Runtime

Default execution should happen in HiClaw Worker containers.

Best suited for:

- planning;
- workflow generation;
- documentation;
- knowledge tasks;
- light code-analysis tasks;
- MCP-mediated tool use.

### 14.2 Manager-Hosted Coding CLI Runtime

For coding tasks, HiClaw’s coding CLI delegation is a strong v1 fit.

Recommended v1 policy:

- `coding-worker` handles planning, context gathering, and iteration logic;
- actual heavy code editing may be delegated to a manager-hosted coding CLI in the Manager workspace;
- results are sent back through the Worker / Manager workflow and published to GitLab only after validation.

This lets ClawCluster gain practical coding power quickly without immediately designing a fully separate per-task code runner fleet.

### 14.3 Future Dedicated Code Runners

If isolation or scale requirements grow, EchoThink can later add dedicated ephemeral code runners.

That is a valid phase-2 or phase-3 enhancement, but it should not block the initial HiClaw-based implementation.

## 15. Security and Credential Model

HiClaw materially changes the preferred security model for ClawCluster.

### 15.1 Worker Credential Policy

Workers should hold:

- their own Higress consumer token;
- only the minimum room and storage references needed;
- no long-lived upstream provider secrets;
- no raw GitHub PATs or other external API master credentials.

### 15.2 Gateway-Owned Secrets

Higress and associated MCP configuration should hold the real upstream secrets.

This is one of the strongest reasons to adopt HiClaw:

- Workers can be compromised without leaking core provider credentials;
- access can be granted and revoked at the gateway layer;
- per-Worker tool and route policy becomes enforceable centrally.

### 15.3 Human Visibility as a Safety Mechanism

HiClaw’s Matrix-room visibility is not just a UX detail; it is a governance mechanism.

For ClawCluster, this means:

- important delegation should be visible;
- blocking questions should be visible;
- risky decisions should happen in rooms where humans can step in;
- the publication bridge should record room identifiers for traceability.

## 16. Task Lifecycle

The task lifecycle should now be understood as an EchoThink-to-HiClaw loop.

### 16.1 Intake

1. A human creates or updates an Outline document, GitLab issue, or explicit task request.
2. n8n or an intake service receives the event.
3. The intake bridge creates a canonical `work_item` in Supabase.
4. The relevant source content is staged in storage if needed.
5. The HiClaw Manager is notified.

### 16.2 Team Setup

6. The Manager reads the structured work item.
7. The Manager determines the required Worker type.
8. The Manager creates or selects the Worker.
9. The Manager creates or reuses the Matrix room for the task.
10. The Manager writes or updates `spec.md`, metadata, and references in shared storage.

### 16.3 Execution

11. The Worker reads its task spec from shared storage and room context.
12. The Worker performs planning, tool use, and artifact generation.
13. If coding is required, the Worker may delegate to a manager-hosted coding CLI.
14. The Worker reports progress and blocking issues in the room.

### 16.4 Validation and Approval

15. Validation runs through a `qa-worker`, automated checks, or both.
16. If the output crosses an approval threshold, the approval bridge records and requests a human decision.
17. If the task is rejected or blocked, the Manager re-routes work or requests clarification.

### 16.5 Publication

18. After validation and approval, the publisher bridge writes the result to the appropriate EchoThink systems.
19. Artifacts, refs, traces, and room ids are linked back to the `work_item`.
20. The task is marked complete, failed, or awaiting follow-up.

## 17. Workload-Specific Patterns

### 17.1 Workflow Authoring

Recommended pattern:

1. Human writes the brief in Outline.
2. Intake bridge creates `workflow.author` work item.
3. Manager assigns a `workflow-worker`.
4. Worker drafts Dify and/or n8n definitions.
5. Drafts are stored in shared storage and summarized in the Matrix room.
6. Human approves publication.
7. Publisher bridge writes draft resources to Dify and n8n.
8. Summary and links are written back to Outline.

### 17.2 Coding

Recommended v1 pattern:

1. Human writes spec in Outline and optionally links a GitLab issue.
2. Intake bridge creates `code.implement` work item.
3. Manager assigns a `coding-worker`.
4. Worker gathers repo context and requirements.
5. Worker delegates heavy implementation to manager-hosted coding CLI when appropriate.
6. Resulting patches, notes, and test output are reviewed by `qa-worker`.
7. Publisher bridge creates GitLab branch and Merge Request.
8. Human review remains required for merge to protected branches.

### 17.3 Planning and Documentation

Recommended pattern:

1. Human updates Outline.
2. Intake bridge creates `plan.support` or `plan.breakdown` work item.
3. Manager assigns a `planner-worker`.
4. Worker produces plans, summaries, ADR drafts, or tracking updates.
5. Publisher bridge writes the draft back to Outline and optionally updates structured task state in Supabase.
6. `knowledge-worker` can then sync stable facts to Graphiti.

## 18. Network and Deployment Model

### 18.1 Cluster Pattern

ClawCluster should be a dedicated HiClaw deployment in its own cluster.

Core services in that cluster:

- Higress Gateway;
- Tuwunel Matrix;
- Element Web;
- HiClaw Manager;
- one or more Worker containers;
- shared storage sync configuration.

### 18.2 Required Cross-Cluster Access

The HiClaw cluster needs private access to the following EchoThink services:

- Outline API;
- GitLab API;
- Supabase/Kong API;
- Hatchet endpoints as needed for task triggering and status bridging;
- Graphiti API;
- LiteLLM API;
- MinIO S3 endpoint;
- Langfuse ingestion endpoint;
- optionally Dify and n8n APIs for draft publication.

### 18.3 Recommended Connectivity Pattern

Recommended v1 pattern:

- private VPN or private ingress between clusters;
- mTLS between HiClaw-side services and EchoThink endpoints where feasible;
- no public inbound access to Worker containers;
- Worker egress restricted to Higress, Matrix, shared storage, and approved infra endpoints.

## 19. Observability and Learning Loop

HiClaw adds operational observability; EchoThink still owns cross-platform observability.

| Signal | Destination |
|--------|-------------|
| Matrix room activity and escalations | HiClaw / Matrix history |
| LLM trace, latency, token cost | Langfuse |
| work item and approval state | Supabase + Hatchet |
| Worker identity, room id, consumer id | Supabase mirrored refs |
| generated artifacts | MinIO + `artifacts` table |
| durable knowledge from outputs | Graphiti |
| code review and merge discussion | GitLab |

Each task run should be attributable by:

- work item id;
- workspace id;
- Matrix room id;
- Worker id;
- Higress consumer id;
- skill version;
- model group or upstream route;
- approval outcome;
- published external refs.

## 20. Recommended Implementation Plan

### Phase 0 — HiClaw Base Deployment

- Deploy a dedicated HiClaw environment in the separate ClawCluster cluster.
- Stand up Higress, Tuwunel, Element, Manager, and a minimal Worker set.
- Prove private connectivity from HiClaw to EchoThink services.

### Phase 1 — EchoThink Intake and Publication Bridges

- Add `clawcluster` schema and structured work item tables in Supabase.
- Implement Outline and GitLab intake bridges.
- Implement publication bridges for Outline and GitLab.
- Mirror Matrix room ids and Worker refs into Supabase.

### Phase 2 — Gateway and MCP Integration

- Configure Higress to front agent traffic.
- Point Higress LLM routes to EchoThink LiteLLM.
- Expose GitLab and other tools through MCP via Higress.
- Enforce per-Worker token and route scopes.

### Phase 3 — First Worker Roles and Skills

- Ship `planner-worker`, `workflow-worker`, and `knowledge-worker`.
- Add initial skills for planning, workflow drafting, graph sync, and documentation.
- Make Outline-driven planning the first closed loop.

### Phase 4 — Coding Workflow

- Add `coding-worker` and `qa-worker`.
- Enable manager-hosted coding CLI delegation.
- Implement GitLab MR publication and review loops.
- Keep merge control with humans.

### Phase 5 — Overnight Operation and Scale-Out

- Add Manager heartbeat and idle Worker lifecycle policies.
- Add nightly planning, validation, and review cycles.
- Expand MCP tool coverage.
- Evaluate whether dedicated ephemeral code runners are needed beyond manager-hosted CLI delegation.

## 21. Definition of “Ready” for ClawCluster v1

ClawCluster v1 should not be considered ready just because HiClaw is deployed.

It is ready only when all of the following are true:

1. HiClaw is deployed as the ClawCluster runtime in the separate cluster.
2. Outline and GitLab events can create structured `work_items` in EchoThink.
3. The HiClaw Manager can consume those work items and assign Workers.
4. Worker permissions are enforced through Higress consumer tokens and route policy.
5. Shared task specs and results are stored in MinIO-backed shared storage.
6. All LLM calls still traverse the EchoThink budget and observability path.
7. Human intervention is possible through Matrix rooms for risky or blocked work.
8. Approved outputs can be published back into Outline, GitLab, Dify, and n8n through controlled bridges.
9. At least one closed-loop flow exists for each workload family: planning, workflow authoring, and coding.

If these conditions are not met, the system is still an early prototype rather than an operational digital employee platform.

## 22. Recommended First Milestone

The most leverage-efficient first milestone is now:

> `Outline brief -> structured work item -> HiClaw Manager -> planner/workflow Worker -> Matrix-visible supervision -> human approval -> draft published back to Outline/Dify/n8n`

This milestone validates:

- the HiClaw Manager + Worker collaboration model;
- the Outline-first / Matrix-second human workflow split;
- the shared storage handoff pattern;
- the publisher bridge pattern;
- the Higress-backed security model.

After that milestone succeeds, the next major step is the coding workflow with manager-hosted CLI delegation and GitLab Merge Request publication.

## 23. Open Questions

These questions remain open, but they are now framed in a HiClaw-based context:

- Should the HiClaw Manager be notified directly by the intake bridge, or should Hatchet remain the mandatory durable trigger owner?
- Should the HiClaw deployment use the existing EchoThink MinIO bucket layout directly, or start with a dedicated HiClaw bucket and converge later?
- Should Higress only front agent-to-tool traffic, or should it eventually become the primary agent-facing gateway for all internal services?
- How much day-to-day human interaction should happen in Matrix versus being mirrored back into Outline comments and documents?
- When should EchoThink introduce dedicated ephemeral code runners beyond HiClaw’s manager-hosted coding CLI delegation model?
- Should some human approvals be handled directly inside Matrix rooms, or always mirrored into a formal Supabase approval object first?

These are design choices to refine during implementation; they do not change the central architectural decision that ClawCluster will be built on top of HiClaw.
