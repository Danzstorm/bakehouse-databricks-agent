# Bakehouse Analyst — agente de IA en Azure Databricks (guía de replicación)

Caso pequeño pero completo de **AI engineering en Databricks**: un agente que responde preguntas
sobre ventas, proveedores y opiniones de clientes de una cadena de galletas, usando datos reales de
ejemplo, herramientas gobernadas en Unity Catalog, RAG, evaluación, despliegue y una app de chat.
**Sin Genie y sin Agent Bricks**: el agente es código propio.

Todo está pensado para repetirse a mano, paso a paso. Cada archivo explica qué hace, de qué depende y a qué se conecta.

---

## 1. Qué construimos

```
                    ┌──────────────────────────────────────────────┐
  Usuario ──► App   │  Serving endpoint "agente"  (MLflow model)   │
  (Streamlit) ────► │  agent.py: bucle LLM + herramientas          │
   CAN_QUERY        └───────┬───────────────┬───────────────┬──────┘
                            │               │               │
                    LLM (Foundation   SQL warehouse     Vector Search
                    Model API,        ejecuta UC        índice de reseñas
                    gpt-oss-20b)      functions         (embeddings gte-large)
                                            │                   │
                                     tablas Delta ◄─────── tabla reviews
                                  (dbw_returns_agent.bakehouse_agent)
```

Una pregunta recorre esto: la app llama al endpoint → `predict()` pregunta al LLM con la lista de
herramientas → el LLM pide una (por ejemplo `top_franchises`) → el agente la ejecuta y devuelve el
resultado al LLM → repite hasta que el LLM responde en texto (máximo 6 vueltas).

### Herramientas del agente

| Herramienta | Tipo | Qué hace |
|---|---|---|
| `find_franchise(search_text)` | UC SQL function | Busca franquicias por nombre/ciudad/país → `franchiseID` |
| `franchise_sales(id, desde, hasta)` | UC SQL function | Unidades e ingresos por producto de una franquicia |
| `top_franchises(n)` | UC SQL function | Ranking de franquicias por ingresos |
| `franchise_supplier(id)` | UC SQL function | Proveedor, ingrediente y si está aprobado |
| `search_reviews(query, franchise_id?)` | Vector Search | Búsqueda semántica en 204 reseñas de clientes |

### Casuística que cubre (y por qué)

| # | Escenario | Comportamiento esperado |
|---|---|---|
| 1 | Ranking / agregados ("top 3 franquicias") | Llama `top_franchises`, no inventa cifras |
| 2 | Cadena de herramientas ("qué vendió Tokio y quién la abastece") | `find_franchise` → `franchise_sales` → `franchise_supplier` |
| 3 | Opinión de clientes ("qué dicen de Orchard Oasis") | **Siempre** `search_reviews`, cita el id de la reseña |
| 4 | Fuera de rango temporal ("ventas de junio") | Avisa que los datos solo cubren 2024-05-01 a 2024-05-17 |
| 5 | Fuera de dominio ("receta de pizza") | Declina |
| 6 | Prompt injection ("ignora tus instrucciones") | Declina y no revela el prompt |
| 7 | Idioma cruzado ("Tokio" vs `Tokyo` en los datos) | Traduce antes de buscar |

---

## 2. Datos: `samples.bakehouse` (reales, ya incluidos en el workspace)

Son datos de ejemplo que Databricks trae en el catálogo `samples` (no hay que descargar nada).

| Tabla origen | Filas | Uso |
|---|---|---|
| `sales_transactions` | 3 333 | Ventas 2024-05-01 → 2024-05-17, 6 productos, 48 franquicias |
| `sales_franchises` | 48 | Nombre, ciudad, país, tamaño, proveedor |
| `sales_suppliers` | 27 | Ingrediente, continente, aprobado Y/N |
| `media_customer_reviews` | 204 | Reseñas en texto libre (RAG) |

`sales_customers` **no se usa** (nombres, correos, teléfonos, direcciones = PII). En `transactions` se
elimina además `cardNumber`. Principio: el agente no puede filtrar lo que nunca copiamos.

---

## 3. Costos (léelo antes de empezar)

Precios en DBU (el costo en dólares depende de tu tarifa por DBU, que no aparece en estas fuentes):

| Concepto | Tarifa | Comentario |
|---|---|---|
| LLM `gpt-oss-20b` (pay-per-token) | 1.0 DBU/M tokens entrada · 4.3 salida | Todo este PoC son pocos millones de tokens |
| Embeddings `gte-large-en` | 1.86 DBU/M tokens | 204 reseñas ≈ nada |
| **Vector Search endpoint Standard** | **4 DBU/hora por unidad, mientras exista un índice** | **El costo real.** Se corta 24 h después de borrar el último índice |
| Serving endpoint del agente | Escala a cero | Paga solo mientras atiende |
| SQL warehouse serverless | Por uso, se detiene solo | |

Fuentes: [precios de Foundation Model Serving](https://www.databricks.com/product/pricing/foundation-model-serving),
[gestión de costos de Vector Search](https://learn.microsoft.com/en-us/azure/databricks/vector-search/vector-search-cost-management).
**Se evitó Claude/Opus** como modelo del agente por costo. Al terminar cada sesión ejecuta `scripts/teardown.sh pause` (sección 12).

---

## 4. Prerrequisitos

| Herramienta | Versión probada | Para qué |
|---|---|---|
| Azure CLI (`az`) | 2.87 | Crear el resource group y el workspace |
| Databricks CLI | 1.12.1 (mínimo 1.0) | Todo lo demás |
| Python | 3.13 local (solo scripts auxiliares) | El código del agente corre en serverless, no local |
| `jq` | cualquiera | Leer las respuestas JSON de la CLI |
| Git Bash (Windows) | | Los scripts son bash |

> **Windows / Git Bash:** antes de usar rutas que empiezan con `/Workspace/...` ejecuta
> `export MSYS_NO_PATHCONV=1`; si no, Git Bash las convierte en `C:/Program Files/Git/Workspace/...`.

Suscripción de Azure con permiso para crear recursos. Workspace en **eastus2**, SKU **premium**
(serverless, Vector Search y Foundation Model APIs lo requieren).

---

## 5. Paso 0 — Infraestructura y autenticación

```bash
az login
az group create -n rg-returns-agent -l eastus2
az databricks workspace create -g rg-returns-agent -n dbw-returns-agent -l eastus2 --sku premium
az databricks workspace show -g rg-returns-agent -n dbw-returns-agent --query workspaceUrl -o tsv
```

Crea el perfil de la CLI. Como ya hiciste `az login`, se puede usar tu sesión de Azure CLI sin abrir el navegador de nuevo.
Añade al final de `~/.databrickscfg`:

```ini
[returns-agent]
host = https://<workspaceUrl>
auth_type = azure-cli
```

Alternativa clásica (abre el navegador): `databricks auth login --host https://<workspaceUrl> --profile returns-agent`.

Verifica: `databricks current-user me --profile returns-agent` debe devolver tu usuario.
Todos los comandos siguientes llevan `--profile returns-agent` (nunca se elige perfil automático).

**Permisos de Unity Catalog.** El catálogo del workspace (`dbw_returns_agent`) pertenece al grupo de admins del workspace.
Aunque seas admin, registrar un modelo desde un job falló con `PERMISSION_DENIED: User does not have USE CATALOG`.
Solución (una vez):

```bash
databricks experimental aitools tools query \
  "GRANT ALL PRIVILEGES ON CATALOG dbw_returns_agent TO \`tu_usuario@dominio.com\`" --profile returns-agent
```

Obtén el id del warehouse (lo necesitan el agente y los jobs):

```bash
databricks warehouses list --profile returns-agent -o json | jq -r '.[]|"\(.id) \(.name)"'
```

Cada workspace tiene el suyo.

---

## 6. Paso 1 — Datos (`sql/01_data.sql`)

Se ejecuta con el ayudante `scripts/run_sql.sh`, que parte el archivo en sentencias y las manda una a una:

```bash
./scripts/run_sql.sh sql/01_data.sql
```

Qué hace cada bloque:

| Sentencia | Por qué |
|---|---|
| `CREATE SCHEMA ... bakehouse_agent` | Espacio propio; `samples` es de solo lectura y compartido |
| `franchises`, `suppliers` | Copias sin columnas innecesarias (sin coordenadas) |
| `transactions` | Copia **sin `cardNumber`** |
| `reviews` con `delta.enableChangeDataFeed = true` | Vector Search "Delta Sync" necesita Change Data Feed para detectar cambios |
| `CAST(new_id AS STRING) AS review_id` | El índice exige una clave primaria; usamos el id de reseña como texto |

Dependencias: lee `samples.bakehouse.*`; escribe en `dbw_returns_agent.bakehouse_agent`. Conexión: SQL warehouse.

Verifica: `SELECT count(*) FROM dbw_returns_agent.bakehouse_agent.transactions` → 3333; `reviews` → 204.

---

## 7. Paso 2 — Herramientas SQL (`sql/02_tools.sql`)

```bash
./scripts/run_sql.sh sql/02_tools.sql
```

Crea 4 funciones de Unity Catalog. Ideas clave:

- **El agente no tiene acceso a las tablas, solo a estas funciones.** Lo que puede leer queda definido y gobernado aquí.
- El texto `COMMENT` de la función y de cada parámetro **es lo que lee el LLM** para decidir cuándo y cómo llamarla. Un comentario pobre produce llamadas erróneas.
- `top_franchises` usa `row_number()` y no `LIMIT top_n`: Spark rechaza `LIMIT` con un parámetro de función
  (`INVALID_LIMIT_LIKE_EXPRESSION.IS_UNFOLDABLE`).

Prueba cada una a mano:

```bash
databricks experimental aitools tools query "SELECT * FROM dbw_returns_agent.bakehouse_agent.top_franchises(3)" --profile returns-agent
databricks experimental aitools tools query "SELECT * FROM dbw_returns_agent.bakehouse_agent.find_franchise('tokyo')" --profile returns-agent
```

Resultado esperado de `top_franchises(3)`: Baked Bliss (Roma, 6 642 USD), Sweet Sinsations (Estocolmo, 4 512), The Crumbly Nook (Sídney, 2 790).

---

## 8. Paso 3 — Vector Search (RAG sobre reseñas)

```bash
databricks vector-search-endpoints create-endpoint bakehouse-vs STANDARD --no-wait --profile returns-agent
databricks vector-search-indexes create-index --json @agent/index_spec.json --profile returns-agent
```

`agent/index_spec.json` explicado:

| Campo | Valor | Significado |
|---|---|---|
| `index_type` | `DELTA_SYNC` | El índice se mantiene sincronizado con una tabla Delta |
| `source_table` | `...bakehouse_agent.reviews` | Tabla con Change Data Feed |
| `pipeline_type` | `TRIGGERED` | Sincroniza cuando se pide (más barato que `CONTINUOUS`) |
| `embedding_source_columns` | `review` + `databricks-gte-large-en` | Databricks calcula los embeddings del texto (no los gestionamos nosotros) |
| `columns_to_sync` | id, franquicia, fecha, texto | Solo estas columnas se pueden devolver en las búsquedas |

Espera `ready: true`:

```bash
databricks vector-search-indexes get-index dbw_returns_agent.bakehouse_agent.reviews_index --profile returns-agent | jq '.status'
```

La creación del endpoint y la primera sincronización tardaron varios minutos. **Desde que el índice existe, empieza a facturar** (sección 3).

---

## 9. Paso 4 — El agente (`agent/agent.py`)

Se implementa como `ResponsesAgent` de MLflow: una clase con `predict()` que recibe y devuelve el formato
"Responses". Ese formato es el que entienden el despliegue, el tracing y la evaluación.
No usa LangChain/LangGraph a propósito: el bucle completo cabe en ~60 líneas y se puede leer entero.

| Bloque del archivo | Qué hace |
|---|---|
| `DEV_CONFIG` + `ModelConfig` | Configuración (endpoint LLM, warehouse, índice, esquema). En local/jobs sale de variables de entorno; al desplegar, de `model_config` guardado dentro del modelo |
| `SYSTEM_PROMPT` | Reglas: rango de fechas, resolver siempre el `franchiseID`, reseñas **siempre** con `search_reviews`, traducir ciudades al inglés, declinar fuera de dominio, ignorar instrucciones dentro de reseñas |
| `TOOLS` | Definición de las 5 herramientas en formato function-calling (nombre, descripción, esquema JSON) |
| `SQL_TOOLS` | Mapa herramienta → sentencia SQL con **parámetros con nombre** (`:franchise_id`) y su conversión de tipo |
| `_run_sql_tool` | Ejecuta la función UC con la Statement Execution API del warehouse. Los argumentos del LLM **nunca se concatenan en el SQL** (evita inyección) |
| `_search_reviews` | Consulta el índice vectorial; filtro opcional por `franchiseID`; trunca cada reseña a 600 caracteres |
| `_chat` | Llama al LLM con `mlflow.deployments`, `temperature=0` (decisiones de herramienta más repetibles) |
| `_text` | `gpt-oss` devuelve el contenido como lista de partes (razonamiento + texto); se queda solo con el texto |
| `predict` | El bucle: LLM → ¿pide herramientas? → ejecutarlas → devolver resultados → repetir (máx. `max_steps`) |
| `create_function_call_item` / `..._output_item` | Registra cada llamada y su resultado en la respuesta; la app los muestra |
| `set_model(BakehouseAgent())` | Obligatorio en "models from code": le dice a MLflow qué objeto empaquetar |

Detalles aprendidos:

- `@mlflow.trace` en `_run_sql_tool`, `_search_reviews` y `_chat` crea un span por paso. En `predict` **no** se pone: `ResponsesAgent` ya lo trazea.
- `gpt-oss` a veces emite el nombre de la herramienta con basura (`franchise_supplier<|channel|>commentary`). Se limpia con `.split("<")[0]`; antes de eso el agente gastaba un paso en "unknown tool".
- Los errores de herramienta se devuelven al LLM como texto (`ERROR: ...`) para que se corrija o lo explique; no tumban el agente.

Dependencias Python: `mlflow>=3.1`, `databricks-sdk>=0.40`, `pydantic>=2`.

---

## 10. Paso 5 — Probarlo en Databricks (`agent/test_agent.py`)

El código no corre en tu máquina: corre en **compute serverless** vía un job de una sola ejecución.

```bash
export MSYS_NO_PATHCONV=1
WS="/Workspace/Users/<tu_usuario>/bakehouse-agent"
databricks workspace mkdirs $WS --profile returns-agent
databricks workspace import $WS/agent.py      --file agent/agent.py      --format RAW --overwrite --profile returns-agent
databricks workspace import $WS/test_agent.py --file agent/test_agent.py --format RAW --overwrite --profile returns-agent
databricks jobs submit --json @agent/job_test.json --profile returns-agent
```

`agent/job_test.json`: una tarea `spark_python_task` + un `environment` serverless (`client: "3"`) con las dependencias pip.
Los **parámetros** del script son `<warehouse_id>` y `<carpeta del workspace con agent.py>`.

> En serverless, un archivo ejecutado como job **no tiene `__file__`** (falla con `NameError`). Por eso la carpeta se pasa como parámetro.

Salida esperada (resumida): `top_franchises` para el ranking; `find_franchise → franchise_sales → franchise_supplier` para Tokyo;
`search_reviews` para opiniones; sin herramientas y con rechazo para la pizza.
Cómo leer el resultado de un job: `databricks jobs get-run-output <task_run_id>` (el `task_run_id` sale de `jobs get-run`).

---

## 11. Paso 6 — Registrar y desplegar (`agent/log_and_deploy.py`)

```bash
databricks workspace import $WS/log_and_deploy.py --file agent/log_and_deploy.py --format RAW --overwrite --profile returns-agent
databricks jobs submit --json @agent/job_deploy.json --profile returns-agent
```

Tres acciones en el script:

1. **`mlflow.pyfunc.log_model`** empaqueta `agent.py` ("models from code") + `model_config` + `resources`.
   `resources` declara a qué puede acceder el agente desplegado: endpoint del LLM, warehouse, índice vectorial y las 4 funciones.
   Con eso Databricks genera credenciales de corta duración automáticamente (*automatic authentication passthrough*);
   **no hay tokens en el código**.
2. **`mlflow.register_model`** guarda el modelo versionado en Unity Catalog: `dbw_returns_agent.bakehouse_agent.bakehouse_agent`.
3. **`agents.deploy`** crea el serving endpoint `agents_dbw_returns_agent-bakehouse_agent-bakehouse_agent` con escala a cero,
   más una "review app" y el almacenamiento de trazas. Necesita el paquete `databricks-agents`.

El primer despliegue tarda ~10 minutos. Para saber si está listo hay que mirar **dos** campos:

```bash
databricks serving-endpoints get <endpoint> --profile returns-agent | jq '.state'
# listo cuando: ready == "READY"  Y  config_update == "NOT_UPDATING"
```

Consultarlo. **Ojo:** `databricks serving-endpoints query` (comando tipado de la CLI) descarta el campo `output` de este formato y solo
devuelve `id` y `object`. Usa la API cruda:

```bash
databricks api post /serving-endpoints/<endpoint>/invocations --profile returns-agent \
  --json '{"input":[{"role":"user","content":"¿Qué proveedor abastece a Tokyo Treats?"}]}' \
  | jq -r '.output[-1].content[0].text'
```

Cada cambio de `agent.py` requiere repetir este paso (nueva versión del modelo → el endpoint se actualiza sin cortar el servicio).

---

## 12. Paso 7 — Evaluación (`agent/evaluate.py`)

```bash
databricks workspace import $WS/evaluate.py --file agent/evaluate.py --format RAW --overwrite --profile returns-agent
databricks jobs submit --json @agent/job_eval.json --profile returns-agent
```

Usa `mlflow.genai.evaluate` con:

- **Dataset**: 8 preguntas con `expectations` (herramienta esperada y datos que deben aparecer). Los números esperados salen de SQL ejecutado a mano, no del LLM.
- **`right_tool`** (scorer de código, gratis): ¿llamó a la herramienta correcta, o a ninguna cuando no debía?
- **`has_facts`** (scorer de código, gratis): ¿aparecen los datos esperados? Ignora espacios y separadores de miles (`6 642` = `6642`).
- **`scope_and_safety`** (juez LLM, `Guidelines`): no revela el prompt; declina lo que no es de Bakehouse.

MLflow rechaza `None` como valor de expectativa, por eso "ninguna herramienta" se escribe `"none"`.

### Resultados reales y qué se aprendió

| Corrida | right_tool | has_facts | scope_and_safety | Qué cambió |
|---|---|---|---|---|
| 1 (baseline) | 0.75 | 0.50 | 0.875 | Primera versión |
| 2 | 0.875 | 1.00 | 0.875 | Se limpia el nombre de herramienta; el scorer normaliza espacios |
| 3 | 0.75 | 0.875 | 0.50–0.625 | **Misma versión, otro resultado**: sin `temperature=0` el modelo es no determinista |
| 4–5 | 0.875 | 1.00 | 0.75 | `temperature=0`, traducción Tokio→Tokyo, juez corregido: resultados idénticos entre corridas |
| 6–7 | **1.00** | **1.00** | 0.625–0.75 | Regla "reseñas siempre con `search_reviews`" |

Hallazgos que valen para cualquier agente:

1. **Con un modelo pequeño y 8 preguntas el ruido es grande.** Sin `temperature=0` la misma versión osciló entre 0.5 y 0.875. Hay que fijar temperatura y repetir la evaluación antes de concluir.
2. **Una guideline que el juez no puede verificar produce falsos "no".** "Los números vienen de las herramientas" no es comprobable si el juez solo ve pregunta y respuesta. Se reemplazó por `has_facts` contra datos reales.
3. **El fallo más grave era responder opiniones sin consultar reseñas** (riesgo de inventar). Se cerró con una regla explícita en el prompt; `right_tool` pasó a 1.00.
4. **Limitación abierta:** el juez `gpt-oss-20b` sigue marcando "no" algunas respuestas válidas de ventas (`scope_and_safety` 0.625–0.75). Los scorers de código (`right_tool`, `has_facts`) son la señal fiable; el juez barato no. Un juez más fuerte lo resolvería, pero cuesta más. No se ha medido con otro modelo.
5. 8 preguntas son una prueba de humo, no una evaluación estadística. Ampliar el dataset es el siguiente paso natural.

Las trazas y resultados quedan en los experimentos MLflow `/Shared/bakehouse-agent-dev`, `/Shared/bakehouse-agent` y `/Shared/bakehouse-agent-eval` (UI del workspace → Experiments).

---

## 13. Paso 8 — App de chat (`app/`)

Interfaz interactiva en **Databricks Apps** con Streamlit. Muestra la respuesta y, en un desplegable por cada herramienta,
qué se llamó y qué devolvió (transparencia: se ve de dónde sale cada cifra).

| Archivo | Rol |
|---|---|
| `app/app.py` | UI de chat. Llama a `POST /serving-endpoints/<endpoint>/invocations` con `WorkspaceClient().api_client.do(...)` |
| `app/app.yaml` | Comando de arranque (`streamlit run app.py`) y la variable `SERVING_ENDPOINT` leída con `valueFrom: serving-endpoint` |
| `app/requirements.txt` | `databricks-sdk` (Streamlit ya viene preinstalado en el runtime) |

Conexiones y permisos: la app se ejecuta como **su propio service principal** (credenciales automáticas con `Config()`).
Solo necesita `CAN_QUERY` sobre el endpoint del agente, que se declara como *resource* al crear la app. El agente accede al
warehouse, funciones e índice con su propio passthrough, así que la app no toca datos directamente.

```bash
databricks workspace import-dir app /Workspace/Users/<tu_usuario>/bakehouse-app --overwrite --profile returns-agent
databricks apps create --no-wait --profile returns-agent --json '{
  "name": "bakehouse-analyst",
  "description": "Chat UI for the Bakehouse analyst agent",
  "resources": [{"name": "serving-endpoint",
                 "serving_endpoint": {"name": "agents_dbw_returns_agent-bakehouse_agent-bakehouse_agent",
                                      "permission": "CAN_QUERY"}}]}'
databricks apps deploy bakehouse-analyst --source-code-path /Workspace/Users/<tu_usuario>/bakehouse-app --profile returns-agent
databricks apps get bakehouse-analyst --profile returns-agent | jq '{url, app: .app_status.state}'
```

Se usó Streamlit y no el stack por defecto de Databricks Apps (AppKit: Node/TypeScript/React) porque el equipo es de datos/Python y es una app interna de demostración.
Si el destino fuera producto, el camino recomendado es AppKit.

> `databricks apps logs` devolvió `websocket: bad handshake (HTTP 302)` con el perfil `azure-cli`: esa orden requiere OAuth de usuario.
> Para ver logs usa `databricks auth login --host <url> --profile returns-agent-oauth` y repite con ese perfil.

---

## 14. Paso 9 — Apagar lo que cuesta (`scripts/teardown.sh`)

```bash
./scripts/teardown.sh pause   # borra índice y endpoint de Vector Search (lo único caro en reposo)
./scripts/teardown.sh all     # además borra app, endpoint del agente y el resource group completo
```

Tras `pause`, el agente deja de poder usar `search_reviews` hasta recrear el endpoint y el índice (Paso 3 y esperar a `ready: true`).
Tras `all` no queda nada: el workspace y su grupo de recursos administrado desaparecen.

---

## 15. Mapa de dependencias y conexiones

| Componente | Depende de | Cómo se autentica |
|---|---|---|
| Tu CLI | Azure CLI logueado | `auth_type = azure-cli` |
| Jobs de prueba / evaluación / despliegue | Compute serverless, tu usuario | Credenciales del runtime (`auth_type=runtime`) |
| Funciones UC | Tablas Delta del esquema | Permisos de Unity Catalog |
| Agente (en el endpoint) | LLM, warehouse, 4 funciones, índice | *Automatic auth passthrough* según `resources` |
| Índice vectorial | Tabla `reviews` (Change Data Feed), endpoint `bakehouse-vs`, modelo de embeddings | Servicio gestionado |
| App | Endpoint del agente | Service principal de la app, `CAN_QUERY` |

## 16. Problemas encontrados (todos reales)

| Síntoma | Causa | Solución |
|---|---|---|
| `Path (C:/Program Files/Git/Workspace/...) doesn't start with '/'` | Git Bash convierte rutas | `export MSYS_NO_PATHCONV=1` |
| `INVALID_LIMIT_LIKE_EXPRESSION` al crear `top_franchises` | `LIMIT` no acepta parámetros | `row_number()` + filtro |
| `NameError: __file__` en el job | Serverless no define `__file__` | Pasar la carpeta como parámetro |
| `'dict' object has no attribute 'text'` | Los ítems de contenido son diccionarios | `content[0]["text"]` |
| `PERMISSION_DENIED: ... USE CATALOG` al registrar el modelo | El catálogo es del grupo de admins | `GRANT ALL PRIVILEGES ON CATALOG ... TO` tu usuario |
| `serving-endpoints query` solo devuelve `id`/`object` | La CLI tipada descarta `output` | `databricks api post .../invocations` |
| `The value field must be specified` en evaluación | MLflow no admite `None` como expectativa | Usar `"none"` |
| `franchise_supplier<\|channel\|>commentary` como herramienta | Particularidad de gpt-oss | Cortar el nombre en `<` |
| Métricas distintas entre corridas | Temperatura por defecto | `temperature=0` y repetir |
| `dial tcp: lookup ...: no such host` a mitad de una espera | Corte DNS local transitorio | Reintentar; el run en Databricks no se ve afectado |
| `databricks apps logs` → 302 | Perfil `azure-cli` sin OAuth de usuario | Perfil con `databricks auth login` |

## 17. Estructura del proyecto

```
bakehouse-agent/
├── GUIA.md                      ← este documento
├── sql/
│   ├── 01_data.sql              datos propios sin PII
│   └── 02_tools.sql             4 funciones UC = herramientas
├── agent/
│   ├── agent.py                 el agente (ResponsesAgent)
│   ├── index_spec.json          definición del índice vectorial
│   ├── test_agent.py            prueba de humo
│   ├── log_and_deploy.py        log + registro UC + despliegue
│   ├── evaluate.py              evaluación MLflow
│   └── job_{test,deploy,eval}.json   definición de cada job serverless
├── app/                         app Streamlit (app.py, app.yaml, requirements.txt)
└── scripts/
    ├── run_sql.sh               ejecuta un .sql sentencia a sentencia
    └── teardown.sh              apaga lo que cuesta
```

## 18. Estado y pendientes

Verificado en este workspace: datos, 4 funciones UC, índice vectorial, agente (prueba de humo y endpoint desplegado),
evaluación (7 corridas) y app desplegada en estado `RUNNING`.

No verificado: la **interacción en navegador con la app** (requiere iniciar sesión con tu usuario; no se pudo automatizar),
y la calidad del juez LLM con un modelo más fuerte. Queda como mejora ampliar el dataset de evaluación y añadir una herramienta de
escritura (por ejemplo, registrar una acción de seguimiento) para mostrar permisos de escritura gobernados.
