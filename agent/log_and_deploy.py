"""Logs the agent to MLflow, registers it in Unity Catalog and deploys it to Model Serving.

Usage (serverless job): log_and_deploy.py <warehouse_id> <workspace_dir_with_agent.py>

What each block does:
  1. log_model: packages agent.py ("models from code") + its config + the resources it needs.
     `resources` tells Databricks which things the served agent may access; it then creates
     short-lived credentials for them automatically (automatic auth passthrough).
  2. register_model: stores the logged model as a versioned model in Unity Catalog.
  3. agents.deploy: creates the serving endpoint (scale to zero) + review app + tracing config.
"""
import os
import sys

WAREHOUSE_ID, AGENT_DIR = sys.argv[1], sys.argv[2]
os.environ["WAREHOUSE_ID"] = WAREHOUSE_ID

import mlflow
from databricks import agents
from mlflow.models.resources import (
    DatabricksFunction,
    DatabricksServingEndpoint,
    DatabricksSQLWarehouse,
    DatabricksVectorSearchIndex,
)

CATALOG_SCHEMA = "dbw_returns_agent.bakehouse_agent"
UC_MODEL = f"{CATALOG_SCHEMA}.bakehouse_agent"
LLM_ENDPOINT = os.environ.get("LLM_ENDPOINT", "databricks-gpt-oss-20b")
VS_INDEX = f"{CATALOG_SCHEMA}.reviews_index"

mlflow.set_tracking_uri("databricks")
mlflow.set_registry_uri("databricks-uc")
mlflow.set_experiment("/Shared/bakehouse-agent")

config = {
    "llm_endpoint": LLM_ENDPOINT,
    "warehouse_id": WAREHOUSE_ID,
    "vs_index": VS_INDEX,
    "schema": CATALOG_SCHEMA,
    "max_steps": 6,
}
resources = [
    DatabricksServingEndpoint(endpoint_name=LLM_ENDPOINT),
    DatabricksSQLWarehouse(warehouse_id=WAREHOUSE_ID),
    DatabricksVectorSearchIndex(index_name=VS_INDEX),
    *[DatabricksFunction(function_name=f"{CATALOG_SCHEMA}.{f}")
      for f in ("find_franchise", "franchise_sales", "top_franchises", "franchise_supplier")],
]

with mlflow.start_run(run_name="log-agent"):
    info = mlflow.pyfunc.log_model(
        name="agent",
        python_model=os.path.join(AGENT_DIR, "agent.py"),
        model_config=config,
        resources=resources,
        pip_requirements=["mlflow>=3.1", "databricks-sdk>=0.40", "pydantic>=2"],
        input_example={"input": [{"role": "user", "content": "¿Cuáles son las 3 franquicias con más ingresos?"}]},
    )

uc = mlflow.register_model(info.model_uri, UC_MODEL)
print("registered", UC_MODEL, "version", uc.version)

dep = agents.deploy(UC_MODEL, uc.version, scale_to_zero=True)
print("endpoint:", dep.endpoint_name)
print("review app:", dep.review_app_url)
