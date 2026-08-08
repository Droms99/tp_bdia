# TP Integrador — Bases de Datos para IA

Sistema RAG para consulta de documentación técnica.

Integrantes: Martin Birman · Gonzalo Castro · Hernando Schidl

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
├── nosql/                 # análisis del paradigma NoSQL para el caso
├── vectorial/             # modelo de datos vectorial
└── anexos/                # material complementario
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
