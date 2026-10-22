"""Chat UI for the Bakehouse analyst agent (Streamlit).

Connection: the app runs as its own service principal (auto credentials via Config()).
It only needs CAN_QUERY on the agent's serving endpoint; the agent endpoint itself
reaches the warehouse, UC functions and the vector index with its own passthrough auth.
"""
import os

import streamlit as st
from databricks.sdk import WorkspaceClient

st.set_page_config(page_title="Bakehouse analyst", page_icon="🍪")
st.title("🍪 Bakehouse franchise analyst")
st.caption("Sales 2024-05-01 → 2024-05-17 · 48 franchises · customer reviews. "
           "Ask about revenue, products, suppliers or what customers say.")


@st.cache_resource
def client() -> WorkspaceClient:
    return WorkspaceClient()  # credentials come from the app environment


def ask(history: list[dict]) -> list[dict]:
    """POST to the agent endpoint (Responses API) and return its output items."""
    out = client().api_client.do(
        "POST", f"/serving-endpoints/{os.environ['SERVING_ENDPOINT']}/invocations",
        body={"input": history},
    )
    return out["output"]


EXAMPLES = ["¿Cuáles son las 5 franquicias con más ingresos?",
            "¿Qué opinan los clientes de las Outback Oatmeal?",
            "Compara ventas de Tokyo Treats y Baked Bliss"]
if "chat" not in st.session_state:
    st.session_state.chat = []  # [{"role","content","tools"}]

with st.sidebar:
    st.subheader("Ejemplos")
    for e in EXAMPLES:
        if st.button(e):
            st.session_state.pending = e
    if st.button("Limpiar chat"):
        st.session_state.chat = []

for m in st.session_state.chat:
    with st.chat_message(m["role"]):
        st.markdown(m["content"])
        for t in m.get("tools", []):
            with st.expander(f"🔧 {t['name']}({t['args']})"):
                st.code(t["result"][:1500], language="json")

q = st.chat_input("Pregunta sobre las franquicias") or st.session_state.pop("pending", None)
if q:
    st.session_state.chat.append({"role": "user", "content": q})
    with st.chat_message("user"):
        st.markdown(q)
    with st.chat_message("assistant"), st.spinner("Pensando…"):
        history = [{"role": m["role"], "content": m["content"]} for m in st.session_state.chat]
        try:
            items = ask(history)
            calls = {i["call_id"]: {"name": i["name"], "args": i["arguments"], "result": ""}
                     for i in items if i["type"] == "function_call"}
            for i in items:
                if i["type"] == "function_call_output":
                    calls[i["call_id"]]["result"] = i["output"]
            text = next(c["text"] for i in reversed(items) if i["type"] == "message" for c in i["content"])
        except Exception as e:
            calls, text = {}, f"Error calling the agent: {e}"
        st.markdown(text)
        for t in calls.values():
            with st.expander(f"🔧 {t['name']}({t['args']})"):
                st.code(t["result"][:1500], language="json")
    st.session_state.chat.append({"role": "assistant", "content": text, "tools": list(calls.values())})
