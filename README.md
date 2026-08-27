# TP Integrador — Bases de Datos para IA

Sistema RAG para consulta de documentación técnica.

Integrantes: Martin Birman · Gonzalo Castro · Hernando Scheidl

---

## Caso de uso

Una organización tiene su documentación técnica dispersa en manuales, instructivos, normas
internas, procedimientos, preguntas frecuentes y documentos históricos. Encontrar algo puntual
hoy implica buscar a mano entre archivos o preguntarle a alguien con experiencia.

Se diseña una solución de datos que permita cargar esos documentos, clasificarlos, dividirlos
en fragmentos consultables y responder preguntas en lenguaje natural, registrando qué
documentos se usaron para construir cada respuesta. La restricción central es que no todos los
usuarios pueden acceder a todos los documentos: hay documentación restringida por área,
versiones internas, documentos obsoletos e información sensible.

Lo ambientamos en un banco regulado, donde conviven normativa externa que cambia seguido,
políticas internas, procedimientos operativos, manuales de sistemas y documentación histórica
que debe conservarse pero no debe usarse para responder.

## La solución

El trabajo se centra en el diseño de datos, no en el modelo de lenguaje ni en la aplicación. El
punto difícil del caso no es la búsqueda semántica sino el control de acceso: una búsqueda por
similitud es ciega al permiso, y si recupera un fragmento que el usuario no puede ver, la
respuesta generada termina filtrando su contenido aunque el documento nunca se muestre.

Por eso el diseño se apoya en tres definiciones:

1. El filtro de permisos vive dentro del motor de base de datos, mediante seguridad a nivel de
   fila, y no en el código de la aplicación.
2. Cada respuesta guarda exactamente qué fragmentos la originaron, para poder auditarla.
3. La vigencia del documento es parte del criterio de recuperación: lo derogado se conserva
   pero no alimenta respuestas.

## Datos principales identificados

Áreas, usuarios, roles y permisos · tipos de documento · documentos y sus versiones · relaciones
entre documentos (deroga, reemplaza, complementa, referencia) · fragmentos de texto con su
representación vectorial · consultas en lenguaje natural · respuestas · fuentes citadas por cada
respuesta · feedback de los usuarios · registros de acceso y auditoría.

## Tecnología propuesta

PostgreSQL 17 con pgvector, como motor único:

| Necesidad | Mecanismo |
|---|---|
| Entidades y relaciones | Modelo relacional normalizado |
| Metadatos variables por tipo de documento | `JSONB` con índice `GIN` |
| Búsqueda semántica | `pgvector` con índice HNSW y distancia coseno |
| Búsqueda por términos exactos | Búsqueda de texto completo (`tsvector`) en español |
| Control de acceso | *Row-Level Security* |
| Trazabilidad | Tablas de auditoría append-only |
| Volumen de eventos | Particionado declarativo por fecha |

La elección, y las tecnologías que se analizaron y descartaron, se justifican en el informe
técnico.

## Estructura del repositorio

```
tp_bdia/
├── docs/                  # informe técnico y diagramas
│   └── diagramas/         # modelo conceptual, lógico, físico y arquitectura
├── data/
│   ├── corpus/            # documentación de ejemplo
│   └── ejemplos/          # muestras de datos por entidad
├── db/
│   ├── estructura/        # DDL: tablas, restricciones, particiones, RLS
│   ├── datos/             # carga de datos de ejemplo
│   ├── consultas/         # consultas representativas
│   └── indices_vistas/    # índices y vistas materializadas
├── etl/                   # fragmentación, embeddings y generación del dataset
└── vectorial/             # modelo de datos vectorial
```

## Cómo levantar el entorno

Requiere Docker. No hace falta tener PostgreSQL instalado.

```bash
cp .env.example .env
make up        # levanta PostgreSQL 17 con pgvector
make estado    # verifica que las extensiones necesarias estén disponibles
make psql      # abre una sesión SQL dentro del contenedor
make down      # detiene el entorno
make reset     # elimina el volumen y los datos
```

La base queda expuesta en `localhost:5433`, para no chocar con un PostgreSQL local en el 5432.

## Cómo ejecutar la implementación mínima

De cero a la base cargada y las consultas ejecutadas, en un comando:

```bash
make venv     # entorno de Python para el ETL (una sola vez)
make todo     # reset + up + dataset + estructura + cargar + consultas
```

O paso por paso, que es lo que conviene para revisar:

```bash
make up          # levanta PostgreSQL 17 con pgvector
make dataset     # genera los datos de ejemplo a partir del corpus (determinístico)
make estructura  # esquemas, tablas, particiones, RLS, índices y vistas
make cargar      # carga los datos y corre 8 verificaciones de coherencia
make consultas   # ejecuta las seis consultas representativas
```

`make cargar` termina imprimiendo ocho verificaciones que deben dar todas en cero. Comprueban,
entre otras cosas, que ninguna respuesta cite un fragmento que su autor no podía ver y que ninguna
cite un documento derogado. Si alguna devuelve filas, los datos contradicen el diseño.

El generador es determinístico: `make dataset` con la misma semilla produce siempre el mismo
conjunto, así que los números del informe no cambian entre ejecuciones. Lo que produce no se
versiona (`data/generado/`); el corpus fuente sí (`data/corpus/`).

## Consultas incluidas

Seis consultas en `db/consultas/`, cada una con la explicación de qué pregunta responde y por qué
es útil en su cabecera.

| # | Consulta | Qué demuestra |
|---|---|---|
| 1 | Control de acceso | La misma búsqueda, dos usuarios, resultados distintos: el filtro de permisos lo aplica el motor |
| 2 | Búsqueda híbrida con RRF | Recuperación vectorial y de texto completo fusionadas por *Reciprocal Rank Fusion* |
| 3 | Trazabilidad | De qué fragmentos y de qué versión de qué documento salió cada respuesta |
| 4 | Uso por área | Indicadores de uso, documentos más citados y satisfacción por área |
| 5 | Consultas sin cobertura | Qué le está preguntando la gente que la documentación no responde |
| 6 | Cadena de derogación | Recorrido recursivo del grafo documental y prueba de que lo derogado no responde |

Los datos de ejemplo son un corpus de 46 documentos bancarios simulados en siete formatos —PDF,
DOCX, HTML, Markdown, TXT, JSON y CSV—, porque es como una organización tiene su documentación de
verdad y porque obliga a que la ingesta normalice metadatos que llegan en siete soportes distintos.
Hay muestras de cada entidad en `data/ejemplos/` para revisar la forma de los datos sin levantar
la base.
