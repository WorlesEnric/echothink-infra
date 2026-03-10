# LiteLLM Gateway

LiteLLM provides a unified OpenAI-compatible API gateway for all LLM providers used in EchoThink.

## Configuration

### Required Environment Variables

Set these in your `.env` file at the project root:

```
OPENAI_API_KEY=sk-...
ANTHROPIC_API_KEY=sk-ant-...
LITELLM_MASTER_KEY=sk-echothink-master-...
LITELLM_DATABASE_URL=postgresql://litellm_user:<password>@postgres:5432/litellm
REDIS_HOST=redis
REDIS_PORT=6379
```

### Model Groups

| Group           | Models                                    | Use Case                        |
|-----------------|-------------------------------------------|---------------------------------|
| `high-quality`  | Claude Opus 4.6, GPT-4o                  | Complex reasoning, analysis     |
| `cost-effective`| Claude Haiku 4.5, GPT-4o-mini            | Routine tasks, summarization    |
| `fast`          | Claude Haiku 4.5, GPT-4o-mini            | Latency-sensitive operations    |
| `code`          | Claude Sonnet 4.6, GPT-4o                | Code generation and review      |
| `embedding`     | text-embedding-3-small, 3-large          | Vector embeddings               |

Routing uses latency-based strategy with automatic fallbacks between groups.

### Creating Virtual Keys

After deployment, create virtual keys for each service:

```bash
curl -X POST "http://litellm:4000/key/generate" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "models": ["high-quality", "cost-effective", "code", "embedding"],
    "metadata": {"user": "dify-service"},
    "max_budget": 100,
    "budget_duration": "30d"
  }'
```

### Adding New API Keys

To add a new provider key at runtime:

```bash
curl -X POST "http://litellm:4000/model/new" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model_name": "high-quality",
    "litellm_params": {
      "model": "anthropic/claude-opus-4-6",
      "api_key": "sk-ant-new-key..."
    }
  }'
```

### Configuring Model Groups

Edit `config.yaml` to add or modify model groups. Each entry under `model_list` maps a `model_name` (the group) to a specific provider model. Multiple entries with the same `model_name` enable load balancing and failover within that group.

### Connecting Services

All internal services use the LiteLLM gateway as their OpenAI-compatible endpoint:

```
OPENAI_API_BASE=http://litellm:4000/v1
OPENAI_API_KEY=<virtual_key_or_master_key>
```
