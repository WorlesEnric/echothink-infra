# Scaling Guide

This document describes when and how to scale each component of the EchoThink infrastructure. It covers both Docker Compose (single-host) and Kubernetes scaling approaches.

## Table of Contents

- [General Scaling Principles](#general-scaling-principles)
- [PostgreSQL](#postgresql)
- [Redis](#redis)
- [MinIO](#minio)
- [LiteLLM](#litellm)
- [Dify](#dify)
- [Supabase Realtime](#supabase-realtime)
- [Hatchet](#hatchet)
- [Graphiti + FalkorDB](#graphiti--falkordb)
- [Langfuse](#langfuse)
- [n8n](#n8n)
- [Outline](#outline)
- [GitLab](#gitlab)
- [Nginx](#nginx)
- [Monitoring Metrics for Scaling Decisions](#monitoring-metrics-for-scaling-decisions)
- [Kubernetes HPA Reference](#kubernetes-hpa-reference)

---

## General Scaling Principles

1. **Scale vertically first.** Adding CPU and memory to an existing container is simpler and has no distributed-systems overhead. Move to horizontal scaling only when vertical limits are reached or high availability is required.
2. **Monitor before scaling.** Every scaling decision should be driven by observed metrics, not assumptions. The "Monitoring Metrics" section below lists the specific signals to watch.
3. **Scale the bottleneck.** Profile the system to find the actual constraint before adding resources. Adding Dify workers does not help if PostgreSQL connections are saturated.
4. **Preserve the shared-nothing property.** Stateless services (LiteLLM, Dify API, Supabase PostgREST, Langfuse) can be replicated freely. Stateful services (PostgreSQL, MinIO, FalkorDB) require careful planning.

---

## PostgreSQL

PostgreSQL is the most critical component. It stores data for every service in the stack.

### Vertical scaling (first step)

- Increase `shared_buffers` to 25% of available RAM (up to 8-16 GB).
- Increase `effective_cache_size` to 50-75% of available RAM.
- Increase `work_mem` for complex queries (start at 64 MB, tune per workload).
- Increase `max_connections` as needed (default 100 is often sufficient with connection pooling).
- Use fast NVMe storage for the data directory.

### Connection pooling with PgBouncer

When services collectively exceed PostgreSQL's `max_connections`, add PgBouncer:

```yaml
# Docker Compose addition
pgbouncer:
  image: edoburu/pgbouncer:latest
  environment:
    DATABASE_URL: postgres://postgres:${POSTGRES_PASSWORD}@postgres:5432/postgres
    POOL_MODE: transaction
    MAX_DB_CONNECTIONS: 50
    DEFAULT_POOL_SIZE: 20
  ports:
    - "6432:6432"
  networks:
    - echothink_net
  depends_on:
    postgres:
      condition: service_healthy
```

Point services at PgBouncer (port 6432) instead of PostgreSQL directly. Use `transaction` pool mode for most services. Supabase Realtime may require `session` mode if it uses prepared statements.

**When to add PgBouncer:**
- Active connection count regularly exceeds 80% of `max_connections`
- Services report connection timeouts
- Connection churn is high (many short-lived connections)

### Read replicas

For read-heavy workloads (Langfuse analytics, Outline search, reporting queries):

1. Set up streaming replication from the primary to one or more replicas.
2. Point read-only workloads to the replica using a separate connection string.
3. Langfuse and Outline both support separate read/write database URLs.

**When to add read replicas:**
- Primary CPU consistently above 70% and the workload is mostly reads
- Query latency on analytical queries degrades interactive service performance
- You need zero-downtime maintenance windows

### Dedicated databases on separate hosts

If a single PostgreSQL host becomes a bottleneck even with replicas:

- Move GitLab to its own PostgreSQL instance (GitLab is resource-intensive)
- Move Langfuse to its own instance (high write volume from traces)
- Keep the remaining services on the shared instance

---

## Redis

Redis serves as cache, message broker (Celery), and rate limiter. It is a single-threaded, in-memory service.

### Vertical scaling

- Increase the memory limit in the container configuration.
- Redis 7 can typically handle 100,000+ operations per second on a single core. CPU is rarely the bottleneck.

### Separate Redis instances

Before moving to Redis Cluster, split workloads across separate Redis instances:

| Instance | Purpose | Services |
|----------|---------|----------|
| `redis-cache` | Caching, sessions | Authentik, Supabase, Outline |
| `redis-queue` | Celery broker | Dify workers |
| `redis-ratelimit` | Rate limiting | LiteLLM, API gateway |

This prevents a cache eviction storm from affecting Celery message delivery.

### Redis Cluster

**When to switch to Redis Cluster:**
- Memory usage on a single instance exceeds the host's available RAM
- You need high availability with automatic failover
- Dify's sharded PubSub throughput exceeds single-instance capacity

Redis Cluster requires a minimum of 6 nodes (3 primaries + 3 replicas). This is typically a Kubernetes deployment concern rather than a Docker Compose one.

---

## MinIO

MinIO stores all file artifacts. A single-node instance handles significant throughput.

### Vertical scaling

- Add more storage capacity by attaching additional disks.
- MinIO benefits from parallel disk I/O -- 4 or more disks improve throughput.

### Distributed mode

**When to scale horizontally:**
- Storage needs exceed a single host's capacity
- You require erasure-coded durability across hosts (tolerating host failures)
- Read throughput is insufficient for concurrent agent artifact retrieval

**Minimum distributed setup:** 2 servers with 4 drives each.

```yaml
# Example distributed MinIO deployment
minio:
  image: minio/minio:latest
  command: server http://minio{1...4}/data{1...4}
  environment:
    MINIO_ROOT_USER: ${MINIO_ROOT_USER}
    MINIO_ROOT_PASSWORD: ${MINIO_ROOT_PASSWORD}
  volumes:
    - /mnt/disk1:/data1
    - /mnt/disk2:/data2
    - /mnt/disk3:/data3
    - /mnt/disk4:/data4
```

For Kubernetes, use the MinIO Operator which manages distributed deployments, automatic TLS, and tenant isolation.

---

## LiteLLM

LiteLLM is the LLM gateway that proxies requests to model providers. It is stateless and horizontally scalable.

### Scaling workers

LiteLLM uses a Gunicorn/Uvicorn worker model. Increase workers for more concurrent LLM requests:

```yaml
litellm:
  command: litellm --config /config.yaml --num_workers 8
```

Rule of thumb: set `num_workers` to 2x CPU cores for I/O-bound LLM proxy workloads.

### Horizontal scaling

Run multiple LiteLLM replicas behind the Nginx load balancer:

```yaml
litellm:
  deploy:
    replicas: 3
```

In Nginx, update the upstream block:

```nginx
upstream litellm {
    server litellm-1:4000;
    server litellm-2:4000;
    server litellm-3:4000;
}
```

**When to scale LiteLLM:**
- Request queue depth increases (visible in LiteLLM metrics)
- Latency to LiteLLM exceeds latency to the upstream provider by more than 50 ms
- Concurrent LLM requests exceed worker count

### Rate limiting and load shedding

LiteLLM has built-in rate limiting per API key and per model. Configure these to match provider rate limits and prevent overload:

```yaml
# litellm config.yaml
general_settings:
  max_parallel_requests: 100
  global_max_parallel_requests: 500
```

---

## Dify

Dify consists of an API server and Celery workers. The API server handles requests; workers execute workflows.

### Scaling workers

The most common scaling need is more Celery workers for concurrent workflow execution:

```yaml
dify-worker:
  deploy:
    replicas: 4
  environment:
    CELERY_WORKER_CONCURRENCY: 8
```

Each worker handles `CELERY_WORKER_CONCURRENCY` concurrent tasks. Total capacity = replicas x concurrency.

### Scaling the API server

The Dify API is stateless and can be replicated behind Nginx:

```yaml
dify-api:
  deploy:
    replicas: 3
```

### Queue separation

For advanced workloads, separate workflow execution queues by type:

- Fast queue: short-running workflows (under 30 seconds)
- Slow queue: long-running workflows with human-in-the-loop steps
- Priority queue: user-triggered workflows that need immediate execution

Dedicate specific worker replicas to each queue to prevent slow workflows from blocking fast ones.

**When to scale Dify:**
- Celery queue depth grows continuously (tasks queuing faster than they complete)
- Average workflow completion time increases without changes to workflow logic
- Human-in-the-loop workflows time out waiting for execution slots

---

## Supabase Realtime

Supabase Realtime handles WebSocket connections for live updates. It is built on Elixir/Phoenix and is designed for high connection counts.

### Vertical scaling

A single Realtime instance can handle tens of thousands of concurrent WebSocket connections. Increase the container's memory allocation to support more connections:

- Each connection uses approximately 50-100 KB of memory.
- 10,000 connections requires approximately 500 MB - 1 GB of memory.

### Horizontal scaling

Supabase Realtime supports multiple nodes communicating through Erlang's distributed process groups:

```yaml
supabase-realtime:
  deploy:
    replicas: 3
  environment:
    REALTIME_IP_VERSION: 4
    ERL_AFLAGS: "-proto_dist inet_tcp"
```

Nginx must use sticky sessions (ip_hash or cookie-based) for WebSocket connections to ensure a client's WebSocket upgrade reaches the same Realtime node.

**When to scale Realtime:**
- WebSocket connection count approaches the per-instance limit
- Message broadcast latency exceeds 100 ms
- Connection drops or timeouts increase

---

## Hatchet

Hatchet is the durable task execution engine. It uses PostgreSQL for state and gRPC for worker communication.

### Scaling workers

Hatchet workers declare a slot count representing concurrent task capacity:

```python
# Worker configuration
worker = hatchet.worker("agent-worker", max_runs=10)
```

Scale by adding more worker instances:

```yaml
hatchet-worker:
  deploy:
    replicas: 4
  environment:
    HATCHET_WORKER_MAX_RUNS: 10
```

Total task capacity = replicas x max_runs per worker.

### Scaling the engine

The Hatchet engine coordinates task scheduling. Multiple engine instances can run concurrently, coordinating through PostgreSQL's `FOR UPDATE SKIP LOCKED`.

**When to scale Hatchet:**
- Task queue depth grows continuously
- Task start latency exceeds 100 ms (normally sub-20 ms)
- Worker utilization (active slots / total slots) consistently above 80%

### Adding RabbitMQ

For deployments processing more than 100 tasks per second, add RabbitMQ for inter-service communication while keeping PostgreSQL as the durable state store:

```yaml
rabbitmq:
  image: rabbitmq:3-management
  environment:
    RABBITMQ_DEFAULT_USER: hatchet
    RABBITMQ_DEFAULT_PASS: ${HATCHET_RABBITMQ_PASSWORD}
  networks:
    - echothink_net
```

---

## Graphiti + FalkorDB

Graphiti is the knowledge graph framework; FalkorDB is the underlying graph database.

### FalkorDB vertical scaling

FalkorDB uses the GraphBLAS engine for matrix-based graph operations. Performance scales with:

- **CPU cores:** Matrix operations parallelize across cores via AVX SIMD instructions.
- **Memory:** The graph must fit in memory for optimal performance. Monitor RSS usage.
- **Storage speed:** Affects RDB snapshot write time and AOF sync latency.

### Graphiti throughput

Graphiti episode ingestion is bounded by LLM call latency (entity extraction uses multiple LLM calls per episode). Scale by:

- Increasing the Graphiti `concurrency_semaphore` to allow more parallel LLM calls per episode.
- Running multiple Graphiti worker processes for parallel episode ingestion.
- Using faster/cheaper models for entity extraction (while monitoring quality via Langfuse).

**When to scale the knowledge graph layer:**
- Episode ingestion queue grows continuously
- Graph query latency exceeds 50 ms at p95
- FalkorDB memory usage approaches the container limit

---

## Langfuse

Langfuse is stateless and horizontally scalable. It writes traces to PostgreSQL.

### Horizontal scaling

```yaml
langfuse:
  deploy:
    replicas: 2
```

**When to scale Langfuse:**
- Trace ingestion latency increases (visible in Langfuse's own health endpoint)
- The dashboard becomes slow under concurrent users
- PostgreSQL write throughput from Langfuse becomes a concern (move to a dedicated database)

---

## n8n

n8n handles integration and automation workflows. It supports webhook triggers and scheduled workflows.

### Scaling considerations

n8n supports a queue mode with separate main and worker processes:

```yaml
n8n-main:
  environment:
    EXECUTIONS_MODE: queue
    QUEUE_BULL_REDIS_HOST: redis

n8n-worker:
  command: n8n worker
  deploy:
    replicas: 2
```

**When to scale n8n:**
- Webhook response times exceed acceptable thresholds
- Workflow execution queue depth grows
- Concurrent workflow executions cause timeouts

---

## Outline

Outline is the wiki/documentation service. It is stateless and can be replicated.

### Horizontal scaling

```yaml
outline:
  deploy:
    replicas: 2
```

Requires sticky sessions or shared file storage for uploaded attachments.

**When to scale Outline:**
- Page load times exceed 2 seconds under concurrent access
- Search indexing falls behind document creation rate

---

## GitLab

GitLab EE is the most resource-intensive component. It has its own scaling architecture.

### Vertical scaling (primary approach)

GitLab benefits significantly from CPU and memory increases:
- Minimum: 4 CPU cores, 8 GB RAM
- Recommended: 8 CPU cores, 16 GB RAM
- For 50+ active users: 16 CPU cores, 32 GB RAM

### Component separation

For larger teams, separate GitLab components onto dedicated hosts:
- Gitaly (git storage) on fast SSD storage
- Sidekiq (background jobs) on a separate host
- PostgreSQL on the shared cluster or a dedicated instance

**When to scale GitLab:**
- Git push/pull operations take more than 5 seconds
- CI pipeline queue times increase
- Sidekiq queue depth grows continuously

---

## Nginx

Nginx is the reverse proxy and TLS termination point for all services.

### Performance tuning

```nginx
worker_processes auto;           # One worker per CPU core
worker_connections 4096;         # Max connections per worker
keepalive_timeout 65;
client_max_body_size 100M;       # For large file uploads

# Enable upstream keepalive for backend connections
upstream dify {
    server dify-api:5001;
    keepalive 32;
}
```

### When Nginx becomes a bottleneck

Nginx can handle tens of thousands of concurrent connections on a single core. If Nginx becomes a bottleneck:

1. Verify `worker_processes` matches CPU count.
2. Increase `worker_connections`.
3. Enable HTTP/2 for multiplexing.
4. Consider moving to a Kubernetes Ingress controller (ingress-nginx) for automatic horizontal scaling.

---

## Monitoring Metrics for Scaling Decisions

Track these metrics to know when to scale. Use Prometheus, Grafana, or the service-specific dashboards.

### PostgreSQL
| Metric | Warning Threshold | Action |
|--------|-------------------|--------|
| Active connections / max_connections | > 80% | Add PgBouncer or increase max_connections |
| CPU usage | > 70% sustained | Vertical scale or add read replicas |
| Disk I/O wait | > 20% | Move to faster storage |
| Replication lag (if using replicas) | > 1 second | Investigate replica capacity |
| Transaction rate | Varies by hardware | Benchmark and set baseline |

### Redis
| Metric | Warning Threshold | Action |
|--------|-------------------|--------|
| Memory usage / maxmemory | > 80% | Increase memory or split instances |
| Connected clients | > 5000 | Investigate connection leaks |
| Evicted keys | > 0 (if eviction is unexpected) | Increase memory |
| Keyspace misses / (hits + misses) | > 50% | Cache is not effective, investigate |

### Dify / Hatchet (Task queues)
| Metric | Warning Threshold | Action |
|--------|-------------------|--------|
| Queue depth | Sustained growth | Add workers |
| Task completion time | > 2x baseline | Investigate or scale |
| Worker CPU usage | > 80% | Add replicas or vertical scale |
| Failed task rate | > 5% | Investigate errors, not a scaling issue |

### MinIO
| Metric | Warning Threshold | Action |
|--------|-------------------|--------|
| Disk usage | > 80% | Add storage or archive old data |
| Request latency (p99) | > 200 ms | Add disks or distribute |
| Error rate | > 1% | Investigate disk health |

### LiteLLM
| Metric | Warning Threshold | Action |
|--------|-------------------|--------|
| Request queue depth | Sustained growth | Add workers or replicas |
| Proxy overhead (total - provider latency) | > 50 ms | Scale LiteLLM |
| Rate limit hits from providers | Increasing | Add provider keys or adjust limits |

---

## Kubernetes HPA Reference

When running on Kubernetes, use Horizontal Pod Autoscalers for stateless services. Below are reference configurations.

### LiteLLM HPA

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: litellm-hpa
  namespace: echothink
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: litellm
  minReplicas: 2
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          averageUtilization: 80
```

### Dify Worker HPA

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: dify-worker-hpa
  namespace: echothink
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: dify-worker
  minReplicas: 2
  maxReplicas: 20
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 60
      policies:
        - type: Pods
          value: 4
          periodSeconds: 60
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
        - type: Pods
          value: 2
          periodSeconds: 120
```

### Supabase Realtime HPA

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: supabase-realtime-hpa
  namespace: echothink
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: supabase-realtime
  minReplicas: 2
  maxReplicas: 8
  metrics:
    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          averageUtilization: 75
```

### Hatchet Worker HPA

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: hatchet-worker-hpa
  namespace: echothink
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: hatchet-worker
  minReplicas: 2
  maxReplicas: 16
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 30
      policies:
        - type: Pods
          value: 4
          periodSeconds: 30
    scaleDown:
      stabilizationWindowSeconds: 300
```

### Langfuse HPA

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: langfuse-hpa
  namespace: echothink
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: langfuse
  minReplicas: 1
  maxReplicas: 4
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
```

### n8n Worker HPA

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: n8n-worker-hpa
  namespace: echothink
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: n8n-worker
  minReplicas: 1
  maxReplicas: 6
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
```
