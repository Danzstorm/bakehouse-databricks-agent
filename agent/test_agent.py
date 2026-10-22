"""Smoke test: runs the agent on serverless compute against a few questions.
Usage (job parameter list): test_agent.py <warehouse_id> <workspace_dir_with_agent.py> [llm_endpoint]
It prints each answer and which tools were called.
"""
import os
import sys

os.environ["WAREHOUSE_ID"] = sys.argv[1]
if len(sys.argv) > 3:
    os.environ["LLM_ENDPOINT"] = sys.argv[3]
# __file__ is not defined when a serverless job runs a workspace file, so the folder is a parameter.
sys.path.insert(0, sys.argv[2])

import mlflow
mlflow.set_tracking_uri("databricks")
mlflow.set_experiment("/Shared/bakehouse-agent-dev")

from agent import BakehouseAgent  # noqa: E402

QUESTIONS = [
    "¿Cuáles son las 3 franquicias con más ingresos?",
    "¿Qué vendió la franquicia de Tokio entre el 1 y el 10 de mayo de 2024 y quién la abastece?",
    "¿Qué opinan los clientes de las galletas Orchard Oasis?",
    "Dame la receta de una pizza napolitana",
]
agent = BakehouseAgent()
for q in QUESTIONS:
    r = agent.predict({"input": [{"role": "user", "content": q}]})
    tools = [o.name for o in r.output if o.type == "function_call"]
    print("\n=== Q:", q, "\n--- tools:", tools, "\n--- A:", r.output[-1].content[0]["text"])
