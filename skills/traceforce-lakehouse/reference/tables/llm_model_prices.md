# llm_model_prices

Global reference: public list prices per model (USD per million tokens), from the LiteLLM price map; the ingest uses it to estimate agent_events.cost_usd.

Joins:
- llm_model_prices.model_key = agent_events.model (exact match; the ingest joins the same way)

| column | type | meaning |
|---|---|---|
| `id` | string | Primary key (uuid as text). |
| `model_key` | string | Model id as the price map names it. |
| `provider` | string | The price map's provider (e.g. 'openai', 'anthropic', 'bedrock'). |
| `mode` | string | 'chat', 'responses' or 'completion'. |
| `input_usd_per_mtok` | double | Uncached input price. |
| `cache_read_usd_per_mtok` | double | Cache-read price; NULL when the map has none (the ingest then uses the input price). |
| `cache_write_usd_per_mtok` | double | Cache-write price; NULL when the map has none (the ingest then uses the input price). |
| `output_usd_per_mtok` | double | Output price. |
| `created_at` | timestamp | Row created (UTC). |
| `updated_at` | timestamp | Row last updated (UTC). |
