# Bakehouse Analyst: AI agent on Azure Databricks

Small but complete AI-engineering case: an agent that answers questions about franchise sales,
suppliers and customer reviews, using real sample data (`samples.bakehouse`), Unity Catalog SQL
functions as tools, RAG with Vector Search, MLflow evaluation, Model Serving and a Databricks App.
No Genie, no Agent Bricks: the agent is plain code.

Start here:

- `docs/Bakehouse-Agent-Guia.pdf`: step-by-step replication guide (Spanish, 36 pages, includes all source code).
- `GUIA.md`: the same guide in Markdown.

Layout: `sql/` (data + tools), `agent/` (agent, deploy, evaluation, job definitions), `app/` (Streamlit chat UI),
`scripts/` (SQL runner, teardown), `docs/` (PDF template and `build_pdf.py`).

Replace `<TU_USUARIO>` and `<WAREHOUSE_ID>` in `agent/job_*.json` with your workspace user and SQL warehouse id.
Vector Search bills while an index exists (4 DBU/hour): run `scripts/teardown.sh pause` when you finish.
