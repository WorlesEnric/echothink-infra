# Outline Agent Workflows

This document describes how to build agent-driven workflows that integrate Outline (the knowledge base), Dify (the agent orchestration engine), n8n (the automation platform), LiteLLM (the LLM gateway), and Graphiti (the temporal knowledge graph). Each workflow follows the same pattern: an event triggers automation logic in n8n, which dispatches work to Dify agent workflows that read and write Outline documents through the Outline API, route LLM calls through LiteLLM, and optionally sync structured knowledge into Graphiti.

## Prerequisites

All services are assumed to be running on the EchoThink internal network with the following base URLs:

| Service    | Internal URL                        | External URL                        |
|------------|-------------------------------------|-------------------------------------|
| Outline    | http://outline:3000                 | https://outline.${DOMAIN}           |
| Dify       | http://dify-api:5001                | https://dify.${DOMAIN}              |
| n8n        | http://n8n:5678                     | https://n8n.${DOMAIN}               |
| LiteLLM    | http://litellm:4000                 | https://litellm.${DOMAIN}           |
| Graphiti   | http://graphiti:8000                | https://graphiti.${DOMAIN}          |

Each service requires API keys or tokens configured as environment variables or n8n credentials.

## Outline API Fundamentals

Outline exposes a RESTful API at `/api`. All requests require an API token passed as a Bearer token in the Authorization header. The API uses JSON request and response bodies.

### Authentication

Create an API token in Outline under Settings > API. Store this token as an n8n credential of type "Header Auth" with the name `Authorization` and value `Bearer <token>`.

### Key Endpoints

**Search documents:**

```
POST /api/documents.search
Content-Type: application/json
Authorization: Bearer <token>

{
  "query": "meeting notes Q1 planning",
  "limit": 10,
  "dateFilter": "month"
}
```

**Read a document:**

```
POST /api/documents.info
Content-Type: application/json
Authorization: Bearer <token>

{
  "id": "<document-id>"
}
```

**Create a document:**

```
POST /api/documents.create
Content-Type: application/json
Authorization: Bearer <token>

{
  "title": "Auto-generated Summary",
  "text": "# Summary\n\nContent here...",
  "collectionId": "<collection-id>",
  "parentDocumentId": "<optional-parent-id>",
  "publish": true
}
```

**Update a document:**

```
POST /api/documents.update
Content-Type: application/json
Authorization: Bearer <token>

{
  "id": "<document-id>",
  "title": "Updated Title",
  "text": "Updated markdown content",
  "append": false
}
```

To append content to an existing document instead of replacing it, set `"append": true`.

**List webhooks:**

```
POST /api/webhooks.list
Content-Type: application/json
Authorization: Bearer <token>
```

**Create a webhook:**

```
POST /api/webhooks.create
Content-Type: application/json
Authorization: Bearer <token>

{
  "name": "n8n-document-events",
  "url": "https://n8n.${DOMAIN}/webhook/outline-events",
  "secret": "<webhook-signing-secret>",
  "events": [
    "documents.publish",
    "documents.update",
    "documents.delete"
  ]
}
```

Outline signs webhook payloads with HMAC-SHA256 using the secret. The signature is sent in the `Outline-Signature` header.

## Workflow 1: Auto-Summarize Meeting Notes

This workflow monitors a "Meeting Notes" collection in Outline. When a new document is published, it extracts the content, generates a structured summary using an LLM via Dify, and writes the summary back as a child document.

### n8n Webhook Configuration

Create a Webhook node in n8n that listens for Outline document publish events.

**Node: Webhook — Outline Document Published**
- HTTP Method: POST
- Path: `/webhook/outline-meeting-summary`
- Authentication: Header Auth
- Response Mode: Immediately respond with 200

**Node: Filter — Meeting Notes Collection Only**
- Condition: `{{ $json.payload.model.collectionId }}` equals the Meeting Notes collection ID
- This prevents the workflow from triggering on documents in other collections

**Node: HTTP Request — Fetch Full Document**
- Method: POST
- URL: `http://outline:3000/api/documents.info`
- Headers: Authorization = `Bearer {{ $credentials.outlineApiToken }}`
- Body: `{ "id": "{{ $json.payload.model.id }}" }`

**Node: HTTP Request — Call Dify Workflow**
- Method: POST
- URL: `http://dify-api:5001/v1/workflows/run`
- Headers: Authorization = `Bearer {{ $credentials.difyApiKey }}`
- Body:
```json
{
  "inputs": {
    "document_title": "{{ $json.data.title }}",
    "document_content": "{{ $json.data.text }}",
    "document_id": "{{ $json.data.id }}"
  },
  "response_mode": "blocking",
  "user": "n8n-automation"
}
```

**Node: HTTP Request — Write Summary to Outline**
- Method: POST
- URL: `http://outline:3000/api/documents.create`
- Headers: Authorization = `Bearer {{ $credentials.outlineApiToken }}`
- Body:
```json
{
  "title": "Summary: {{ $json.inputs.document_title }}",
  "text": "{{ $json.outputs.summary }}",
  "collectionId": "<meeting-notes-collection-id>",
  "parentDocumentId": "{{ $json.inputs.document_id }}",
  "publish": true
}
```

### Dify Workflow: Meeting Notes Summarizer

Create a workflow in Dify with the following node sequence:

1. **Start Node** — Receives `document_title`, `document_content`, and `document_id` as input variables.

2. **LLM Node — Extract Structure** — Calls LiteLLM to parse the meeting notes into structured sections.
   - Model: `gpt-4o` (routed through LiteLLM at `http://litellm:4000/v1`)
   - System prompt:
     ```
     You are a meeting notes analyst. Extract the following from the provided meeting notes:
     - Attendees (list of names)
     - Date and time of the meeting
     - Agenda items discussed
     - Key decisions made
     - Action items with owners and deadlines
     - Open questions or unresolved topics
     Return the result as a structured markdown document.
     ```
   - User prompt: `Title: {{document_title}}\n\nContent:\n{{document_content}}`

3. **LLM Node — Generate Executive Summary** — Produces a concise summary from the structured extraction.
   - Model: `gpt-4o-mini` (routed through LiteLLM)
   - System prompt:
     ```
     You are a concise technical writer. Given a structured extraction of meeting notes,
     write an executive summary in three to five sentences that captures the most important
     decisions and action items. Do not include filler or preamble.
     ```
   - User prompt: `{{extract_structure_output}}`

4. **Template Node — Format Output** — Combines the structured extraction and executive summary into a single markdown document.
   - Template:
     ```
     # Summary: {{document_title}}

     > Auto-generated summary. Source document: {{document_title}}

     ## Executive Summary

     {{executive_summary}}

     ## Detailed Breakdown

     {{structured_extraction}}

     ---
     *Generated automatically by EchoThink Meeting Summarizer*
     ```

5. **End Node** — Returns the formatted summary as the `summary` output variable.

## Workflow 2: Architecture Review Agent

This workflow triggers when a document tagged as an architecture proposal is published. An agent reviews the proposal against existing architecture documents, checks for consistency, and appends review comments.

### n8n Webhook Configuration

**Node: Webhook — Outline Document Published**
- HTTP Method: POST
- Path: `/webhook/outline-architecture-review`
- Response Mode: Immediately respond with 200

**Node: Switch — Route by Event Type**
- Condition: `{{ $json.event }}` equals `documents.publish`
- Fallback: discard the event

**Node: HTTP Request — Fetch Document Metadata**
- Method: POST
- URL: `http://outline:3000/api/documents.info`
- Headers: Authorization = `Bearer {{ $credentials.outlineApiToken }}`
- Body: `{ "id": "{{ $json.payload.model.id }}" }`

**Node: IF — Is Architecture Proposal**
- Condition: The document title contains "Architecture" or "RFC" or "Proposal", OR the document belongs to the Architecture collection
- Expression: `{{ $json.data.title.match(/architecture|rfc|proposal/i) !== null || $json.data.collectionId === '<architecture-collection-id>' }}`

**Node: HTTP Request — Search Related Architecture Docs**
- Method: POST
- URL: `http://outline:3000/api/documents.search`
- Headers: Authorization = `Bearer {{ $credentials.outlineApiToken }}`
- Body:
```json
{
  "query": "{{ $json.data.title }}",
  "collectionId": "<architecture-collection-id>",
  "limit": 5
}
```

**Node: Code — Aggregate Context**
- Concatenate the content of the top 5 related documents into a single context string, truncated to 30,000 characters to fit within LLM context limits.

```javascript
const relatedDocs = $input.all();
let context = "";
for (const doc of relatedDocs) {
  context += `### ${doc.json.document.title}\n\n${doc.json.document.text}\n\n---\n\n`;
}
return [{ json: { context: context.substring(0, 30000) } }];
```

**Node: HTTP Request — Call Dify Architecture Review Workflow**
- Method: POST
- URL: `http://dify-api:5001/v1/workflows/run`
- Headers: Authorization = `Bearer {{ $credentials.difyApiKey }}`
- Body:
```json
{
  "inputs": {
    "proposal_title": "{{ $node['Fetch Document Metadata'].json.data.title }}",
    "proposal_content": "{{ $node['Fetch Document Metadata'].json.data.text }}",
    "related_documents": "{{ $json.context }}",
    "document_id": "{{ $node['Fetch Document Metadata'].json.data.id }}"
  },
  "response_mode": "blocking",
  "user": "architecture-review-agent"
}
```

**Node: HTTP Request — Append Review to Document**
- Method: POST
- URL: `http://outline:3000/api/documents.update`
- Headers: Authorization = `Bearer {{ $credentials.outlineApiToken }}`
- Body:
```json
{
  "id": "{{ $node['Fetch Document Metadata'].json.data.id }}",
  "text": "{{ $json.outputs.review_comments }}",
  "append": true
}
```

### Dify Workflow: Architecture Review

1. **Start Node** — Receives `proposal_title`, `proposal_content`, `related_documents`, and `document_id`.

2. **LLM Node — Analyze Proposal** — Reviews the proposal against the existing architecture context.
   - Model: `claude-sonnet-4-20250514` (routed through LiteLLM)
   - System prompt:
     ```
     You are a senior software architect reviewing a proposal for an open-source
     self-hosted infrastructure stack. You have access to existing architecture
     documents for context.

     Review the proposal for:
     1. Consistency with existing architectural decisions
     2. Potential conflicts with other services in the stack
     3. Security considerations (authentication, network isolation, secrets management)
     4. Operational concerns (resource usage, backup strategy, monitoring gaps)
     5. Missing dependencies or integration points
     6. Scalability implications

     Be specific. Reference existing documents when pointing out conflicts.
     Provide actionable recommendations, not vague suggestions.
     ```
   - User prompt:
     ```
     ## Proposal Under Review
     Title: {{proposal_title}}

     {{proposal_content}}

     ## Existing Architecture Context

     {{related_documents}}
     ```

3. **Template Node — Format Review** — Wraps the review output in a standard review section.
   - Template:
     ```

     ---

     ## Architecture Review (Automated)

     *Reviewed by: Architecture Review Agent*
     *Date: {{current_date}}*

     {{review_analysis}}

     ---
     *This review was generated automatically. Discuss findings with the team before acting on recommendations.*
     ```

4. **End Node** — Returns `review_comments`.

## Workflow 3: Knowledge Graph Sync

This workflow feeds Outline documents into Graphiti as episodes, building a temporal knowledge graph of the team's documented knowledge. It triggers on document publish and update events, extracts entities and relationships, and stores them in the Graphiti MCP server.

### n8n Webhook Configuration

**Node: Webhook — Outline Document Events**
- HTTP Method: POST
- Path: `/webhook/outline-knowledge-sync`
- Response Mode: Immediately respond with 200

**Node: Switch — Route by Event Type**
- Routes for `documents.publish` and `documents.update` (proceed), all others (discard)

**Node: HTTP Request — Fetch Full Document**
- Method: POST
- URL: `http://outline:3000/api/documents.info`
- Headers: Authorization = `Bearer {{ $credentials.outlineApiToken }}`
- Body: `{ "id": "{{ $json.payload.model.id }}" }`

**Node: Code — Prepare Episode Payload**
- Transforms the Outline document into a Graphiti episode format.

```javascript
const doc = $input.first().json.data;
const episode = {
  name: doc.title,
  episode_body: doc.text,
  source: "outline",
  source_description: `Outline document: ${doc.title} (ID: ${doc.id})`,
  reference_time: doc.updatedAt || doc.createdAt,
  group_id: doc.collectionId,
  uuid: doc.id
};
return [{ json: episode }];
```

**Node: HTTP Request — Add Episode to Graphiti**
- Method: POST
- URL: `http://graphiti:8000/api/v1/episodes`
- Headers: Authorization = `Bearer {{ $credentials.graphitiApiToken }}`
- Body:
```json
{
  "name": "{{ $json.name }}",
  "episode_body": "{{ $json.episode_body }}",
  "source": "{{ $json.source }}",
  "source_description": "{{ $json.source_description }}",
  "reference_time": "{{ $json.reference_time }}",
  "group_id": "{{ $json.group_id }}",
  "uuid": "{{ $json.uuid }}"
}
```

When Graphiti processes this episode, it runs the following pipeline automatically:

1. **Entity extraction** — The LLM identifies named entities in the document (services, people, concepts, technologies, decisions).
2. **Relationship extraction** — The LLM identifies typed relationships between entities (depends-on, replaces, authored-by, decided-on).
3. **Entity resolution** — Graphiti deduplicates entities against existing graph nodes, merging references to the same real-world entity.
4. **Temporal invalidation** — If the document updates previously stated facts, Graphiti marks old facts with an `invalid_at` timestamp and creates new facts with the updated information.
5. **Embedding generation** — Both entities and relationships receive vector embeddings for semantic search.

**Node: IF — Check for Errors**
- Condition: HTTP status code is not 200/201
- True path: Send error notification (email, Slack, or other alerting channel)
- False path: Log success

**Node: HTTP Request — Verify Entity Extraction (Optional)**
- Method: POST
- URL: `http://graphiti:8000/api/v1/search`
- Headers: Authorization = `Bearer {{ $credentials.graphitiApiToken }}`
- Body:
```json
{
  "query": "{{ $json.name }}",
  "group_ids": ["{{ $json.group_id }}"],
  "num_results": 5
}
```
- This step verifies that entities were extracted and are retrievable from the graph.

### Handling Document Deletions

When a document is deleted from Outline, the knowledge graph should not remove the entities (they may be referenced by other episodes). Instead, add a deletion episode that records the removal.

**Node: Switch — Route Deletions**
- Condition: `{{ $json.event }}` equals `documents.delete`

**Node: Code — Prepare Deletion Episode**

```javascript
const model = $input.first().json.payload.model;
const episode = {
  name: `Document deleted: ${model.title}`,
  episode_body: `The document "${model.title}" (ID: ${model.id}) was deleted from Outline. ` +
    `Any facts solely sourced from this document should be considered potentially outdated.`,
  source: "outline",
  source_description: `Outline document deletion event for: ${model.title}`,
  reference_time: new Date().toISOString(),
  group_id: model.collectionId,
  uuid: `deletion-${model.id}`
};
return [{ json: episode }];
```

This deletion episode flows through the same Graphiti ingestion pipeline. Graphiti's temporal invalidation logic will evaluate whether any existing facts should be marked as superseded based on the deletion context.

### Full Sync: Backfilling Existing Documents

For initial setup or periodic reconciliation, use an n8n scheduled workflow that iterates through all Outline documents and submits them as episodes.

**Node: Schedule Trigger**
- Interval: Weekly (or on-demand manual trigger)

**Node: HTTP Request — List All Collections**
- Method: POST
- URL: `http://outline:3000/api/collections.list`
- Headers: Authorization = `Bearer {{ $credentials.outlineApiToken }}`

**Node: Loop — For Each Collection**
- Iterates over collections

**Node: HTTP Request — List Documents in Collection**
- Method: POST
- URL: `http://outline:3000/api/documents.list`
- Headers: Authorization = `Bearer {{ $credentials.outlineApiToken }}`
- Body:
```json
{
  "collectionId": "{{ $json.id }}",
  "limit": 100,
  "offset": 0
}
```
- Pagination: Use the SplitInBatches node if collections contain more than 100 documents.

**Node: Loop — For Each Document**
- Iterates over documents and submits each as an episode to Graphiti using the same episode creation logic described above.

**Node: Wait — Rate Limiting**
- Wait 2 seconds between Graphiti submissions to avoid overwhelming the LLM calls in the extraction pipeline.

## Outline Webhook Registration

Register all three webhooks in Outline using the API. This can be done as a one-time setup step or managed through an n8n workflow.

```bash
# Meeting Notes Summarizer webhook
curl -X POST https://outline.${DOMAIN}/api/webhooks.create \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${OUTLINE_API_TOKEN}" \
  -d '{
    "name": "n8n-meeting-summarizer",
    "url": "https://n8n.${DOMAIN}/webhook/outline-meeting-summary",
    "secret": "'${WEBHOOK_SECRET}'",
    "events": ["documents.publish"]
  }'

# Architecture Review webhook
curl -X POST https://outline.${DOMAIN}/api/webhooks.create \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${OUTLINE_API_TOKEN}" \
  -d '{
    "name": "n8n-architecture-review",
    "url": "https://n8n.${DOMAIN}/webhook/outline-architecture-review",
    "secret": "'${WEBHOOK_SECRET}'",
    "events": ["documents.publish"]
  }'

# Knowledge Graph Sync webhook
curl -X POST https://outline.${DOMAIN}/api/webhooks.create \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${OUTLINE_API_TOKEN}" \
  -d '{
    "name": "n8n-knowledge-graph-sync",
    "url": "https://n8n.${DOMAIN}/webhook/outline-knowledge-sync",
    "secret": "'${WEBHOOK_SECRET}'",
    "events": ["documents.publish", "documents.update", "documents.delete"]
  }'
```

## Security Considerations

**Webhook signature verification.** Every n8n webhook node should verify the `Outline-Signature` header against the configured webhook secret. In n8n, add a Code node immediately after the Webhook node:

```javascript
const crypto = require('crypto');
const secret = $env.OUTLINE_WEBHOOK_SECRET;
const signature = $input.first().headers['outline-signature'];
const payload = JSON.stringify($input.first().json);
const expected = crypto.createHmac('sha256', secret).update(payload).digest('hex');

if (signature !== expected) {
  throw new Error('Invalid webhook signature');
}

return $input.all();
```

**API token scoping.** Create dedicated Outline API tokens for each workflow rather than sharing a single admin token. Use the minimum required permissions for each token.

**Network isolation.** All inter-service communication happens over the `echothink-internal` Docker network. Webhook URLs exposed to Outline use internal hostnames (e.g., `http://n8n:5678/webhook/...`) rather than public URLs when both services are on the same network. Use public URLs only when services are on separate networks or for external integrations.

**LiteLLM rate limiting.** Configure LiteLLM rate limits per virtual key to prevent runaway agent workflows from exhausting LLM API budgets. Set per-key RPM (requests per minute) and TPM (tokens per minute) limits appropriate for each workflow's expected volume.

## Monitoring and Observability

All LLM calls routed through LiteLLM are automatically logged to Langfuse for cost tracking, latency monitoring, and quality evaluation. To correlate Langfuse traces with specific Outline documents:

1. Pass the Outline document ID as metadata in the Dify workflow's LLM calls.
2. Use Langfuse's trace tagging to associate traces with document IDs and workflow names.
3. Build Langfuse dashboards that show per-workflow cost, latency percentiles, and error rates.

n8n execution logs provide the automation layer observability. Enable execution data saving for all workflows (configured in the n8n compose file via `EXECUTIONS_DATA_SAVE_ON_SUCCESS` and `EXECUTIONS_DATA_SAVE_ON_ERROR`) to maintain a full audit trail of every webhook received and every API call made.
