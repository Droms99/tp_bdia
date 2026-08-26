# Modelo lógico relacional

Traducción del modelo conceptual a un esquema relacional: tablas, columnas, tipos, claves
primarias, claves foráneas y restricciones de integridad. Corresponde al punto 5 del
[informe](../informe.md), donde se justifica cada criterio de traducción, y lo implementa
[`db/estructura/03_tablas.sql`](../../db/estructura/03_tablas.sql).

Los diagramas están escritos en Mermaid para poder versionarlos y ver los cambios en los *diffs*.
Se exportan a `.png` al cierre del trabajo.

**Están generados a partir del catálogo de la base, no transcritos a mano.** Es la única forma de
garantizar que el diagrama y el DDL no se contradigan: si alguien agrega una columna al script y no
al diagrama, el diagrama deja de ser documentación y pasa a ser una afirmación falsa.

## Notación

Notación *crow's foot* de Mermaid. Sobre cada línea va el nombre de la columna que implementa la
clave foránea.

| Símbolo | Lado | Significado |
|---|---|---|
| `\|\|` | padre | La clave foránea es `NOT NULL`: el hijo tiene **exactamente un** padre |
| `\|o` | padre | La clave foránea admite nulo: el hijo tiene **cero o un** padre |
| `o{` | hijo | El padre tiene **cero o más** hijos |
| `o\|` | hijo | Hay unicidad sobre la clave foránea: el padre tiene **a lo sumo un** hijo (relación 1:1) |

En los atributos, `PK` marca la clave primaria, `FK` la clave foránea y `UK` la restricción de
unicidad. Cuando un atributo lleva más de una marca, la segunda va en el comentario. El comentario
indica además si la columna admite nulo, si es generada y si su valor lo asigna el motor
(`identidad`).

---

## Vista general

Las 22 tablas del esquema `core` y sus 34 claves foráneas. Sin atributos, para que se vea la
estructura de dependencias.

Vale una aclaración sobre ese número: el catálogo de PostgreSQL informa 73 restricciones de clave
foránea sobre `core`. Son las mismas 34, replicadas: cuando una tabla particionada participa de una
clave foránea, el motor crea una restricción hija por cada partición. Contarlas sin filtrar las
réplicas duplica el modelo.

```mermaid
erDiagram
    AREA |o--o{ ACL_DOCUMENTO : "area_id"
    AREA ||--o{ DOCUMENTO : "area_id"
    AREA ||--o{ USUARIO : "area_id"
    CHUNK |o--o{ LOG_ACCESO : "chunk_id"
    CHUNK ||--o{ RESPUESTA_FUENTE : "chunk_id"
    CONSULTA ||--o| RESPUESTA : "consulta_id, creado_en"
    DOCUMENTO |o--o{ LOG_ACCESO : "documento_id"
    DOCUMENTO ||--o{ ACL_DOCUMENTO : "documento_id"
    DOCUMENTO ||--o{ DOCUMENTO_ETIQUETA : "documento_id"
    DOCUMENTO ||--o{ DOCUMENTO_RELACION : "documento_destino_id"
    DOCUMENTO ||--o{ DOCUMENTO_RELACION : "documento_origen_id"
    DOCUMENTO ||--o{ DOCUMENTO_VERSION : "documento_id"
    DOCUMENTO_VERSION ||--o{ CHUNK : "documento_version_id"
    ETIQUETA ||--o{ DOCUMENTO_ETIQUETA : "etiqueta_id"
    MODELO_EMBEDDING |o--o{ CONSULTA : "modelo_embedding_id"
    MODELO_EMBEDDING ||--o{ CHUNK : "modelo_embedding_id"
    NIVEL_CONFIDENCIALIDAD ||--o{ DOCUMENTO : "nivel_id"
    NIVEL_CONFIDENCIALIDAD ||--o{ USUARIO : "nivel_habilitacion_id"
    PERMISO ||--o{ ROL_PERMISO : "permiso_id"
    RESPUESTA ||--o{ FEEDBACK : "respuesta_id, respuesta_creado_en"
    RESPUESTA ||--o{ RESPUESTA_FUENTE : "respuesta_id, creado_en"
    ROL |o--o{ ACL_DOCUMENTO : "rol_id"
    ROL ||--o{ ROL_PERMISO : "rol_id"
    ROL ||--o{ USUARIO_ROL : "rol_id"
    TIPO_DOCUMENTO ||--o{ DOCUMENTO : "tipo_documento_id"
    USUARIO |o--o{ ACL_DOCUMENTO : "usuario_id"
    USUARIO ||--o{ ACL_DOCUMENTO : "otorgado_por"
    USUARIO ||--o{ AUDITORIA : "usuario_id"
    USUARIO ||--o{ CONSULTA : "usuario_id"
    USUARIO ||--o{ DOCUMENTO : "creado_por"
    USUARIO ||--o{ DOCUMENTO_VERSION : "creado_por"
    USUARIO ||--o{ FEEDBACK : "usuario_id"
    USUARIO ||--o{ LOG_ACCESO : "usuario_id"
    USUARIO ||--o{ USUARIO_ROL : "usuario_id"
```

---

## Organización y control de acceso

`acl_documento` es la tabla más crítica del modelo: de ella dependen las políticas de seguridad por
fila.

```mermaid
erDiagram
    AREA |o--o{ ACL_DOCUMENTO : "area_id"
    AREA ||--o{ DOCUMENTO : "area_id"
    AREA ||--o{ USUARIO : "area_id"
    DOCUMENTO ||--o{ ACL_DOCUMENTO : "documento_id"
    NIVEL_CONFIDENCIALIDAD ||--o{ DOCUMENTO : "nivel_id"
    NIVEL_CONFIDENCIALIDAD ||--o{ USUARIO : "nivel_habilitacion_id"
    PERMISO ||--o{ ROL_PERMISO : "permiso_id"
    ROL |o--o{ ACL_DOCUMENTO : "rol_id"
    ROL ||--o{ ROL_PERMISO : "rol_id"
    ROL ||--o{ USUARIO_ROL : "rol_id"
    USUARIO |o--o{ ACL_DOCUMENTO : "usuario_id"
    USUARIO ||--o{ ACL_DOCUMENTO : "otorgado_por"
    USUARIO ||--o{ DOCUMENTO : "creado_por"
    USUARIO ||--o{ USUARIO_ROL : "usuario_id"

    AREA {
        integer id PK "identidad"
        text nombre UK
        text descripcion "nulo"
        boolean activa
        timestamptz creado_en
    }
    USUARIO {
        bigint id PK "identidad"
        text identidad_ext UK
        text nombre
        text email UK
        integer area_id FK
        smallint nivel_habilitacion_id FK
        boolean activo
        timestamptz creado_en
        timestamptz baja_en "nulo"
    }
    ROL {
        integer id PK "identidad"
        text nombre UK
        text descripcion "nulo"
    }
    PERMISO {
        integer id PK "identidad"
        text codigo UK
        text descripcion
    }
    ROL_PERMISO {
        integer rol_id PK "FK"
        integer permiso_id PK "FK"
    }
    USUARIO_ROL {
        bigint usuario_id PK "FK"
        integer rol_id PK "FK"
        timestamptz otorgado_en
    }
    NIVEL_CONFIDENCIALIDAD {
        smallint id PK
        text nombre UK
        smallint orden UK
        text descripcion "nulo"
    }
    ACL_DOCUMENTO {
        bigint id PK "identidad"
        bigint documento_id FK
        integer area_id FK "nulo"
        integer rol_id FK "nulo"
        bigint usuario_id FK "nulo"
        timestamptz vigente_desde
        timestamptz vigente_hasta "nulo"
        bigint otorgado_por FK
        timestamptz creado_en
    }
    DOCUMENTO { }
```

**El arco exclusivo.** El modelo conceptual dice que un otorgamiento tiene un sujeto y uno solo, que
puede ser un área, un rol o un usuario. Se implementa con tres claves foráneas que admiten nulo
—de ahí el `|o` en las tres líneas— más la verificación `num_nonnulls(area_id, rol_id, usuario_id) = 1`,
que garantiza que exactamente una esté informada. La alternativa, tres tablas separadas, sería más
estricta pero triplicaría la consulta que la política de RLS ejecuta en cada recuperación.

`usuario` aparece dos veces como padre de `acl_documento`: una como sujeto del otorgamiento
(`usuario_id`, que admite nulo) y otra como quien lo otorgó (`otorgado_por`, obligatoria). Son dos
roles distintos de la misma entidad y por eso son dos columnas.

**`nivel_habilitacion_id` es el techo de la regla de acceso.** Es una propiedad de la persona, no
del rol que cumple: dos usuarios con el mismo rol pueden tener habilitaciones distintas. Sin esta
columna, la primera condición de la regla de acceso no tendría dónde apoyarse.

---

## Catálogo documental

```mermaid
erDiagram
    AREA ||--o{ DOCUMENTO : "area_id"
    AREA ||--o{ USUARIO : "area_id"
    DOCUMENTO ||--o{ DOCUMENTO_ETIQUETA : "documento_id"
    DOCUMENTO ||--o{ DOCUMENTO_RELACION : "documento_destino_id"
    DOCUMENTO ||--o{ DOCUMENTO_RELACION : "documento_origen_id"
    DOCUMENTO ||--o{ DOCUMENTO_VERSION : "documento_id"
    ETIQUETA ||--o{ DOCUMENTO_ETIQUETA : "etiqueta_id"
    NIVEL_CONFIDENCIALIDAD ||--o{ DOCUMENTO : "nivel_id"
    NIVEL_CONFIDENCIALIDAD ||--o{ USUARIO : "nivel_habilitacion_id"
    TIPO_DOCUMENTO ||--o{ DOCUMENTO : "tipo_documento_id"
    USUARIO ||--o{ DOCUMENTO : "creado_por"
    USUARIO ||--o{ DOCUMENTO_VERSION : "creado_por"

    TIPO_DOCUMENTO {
        smallint id PK "identidad"
        text codigo UK
        text nombre
        text descripcion "nulo"
    }
    DOCUMENTO {
        bigint id PK "identidad"
        text codigo UK
        text titulo
        smallint tipo_documento_id FK
        integer area_id FK
        smallint nivel_id FK
        estado_documento estado
        jsonb metadatos
        bigint creado_por FK
        timestamptz creado_en
        timestamptz actualizado_en
    }
    DOCUMENTO_VERSION {
        bigint id PK "identidad"
        bigint documento_id FK "UK"
        text numero_version UK
        date vigente_desde
        date vigente_hasta "nulo"
        text uri_original
        character_64 hash_sha256 UK
        text texto
        bigint creado_por FK
        timestamptz creado_en
    }
    DOCUMENTO_RELACION {
        bigint documento_origen_id PK "FK"
        bigint documento_destino_id PK "FK"
        tipo_relacion_documento tipo PK
        timestamptz creado_en
    }
    ETIQUETA {
        integer id PK "identidad"
        text nombre UK
    }
    DOCUMENTO_ETIQUETA {
        bigint documento_id PK "FK"
        integer etiqueta_id PK "FK"
    }
    AREA { }
    NIVEL_CONFIDENCIALIDAD { }
    USUARIO { }
```

**`documento_relacion` es una autorrelación.** `documento` aparece dos veces como padre —origen y
destino— y la clave primaria es `(origen, destino, tipo)`, porque dos documentos pueden vincularse
por más de un motivo. Una verificación impide que un documento se relacione consigo mismo.

**`documento_etiqueta` es una tabla puente pura**: clave primaria compuesta por las dos foráneas y
ningún atributo propio. `documento_relacion`, en cambio, tiene atributos —el tipo y la fecha— y por
eso es una entidad y no una tabla puente.

**La vigencia sin solapamiento.** `documento_version` lleva una restricción de exclusión
`EXCLUDE USING gist (documento_id WITH =, daterange(vigente_desde, vigente_hasta, '[]') WITH &&)`
que garantiza que un documento no tenga dos versiones vigentes en el mismo instante (RD2). No es una
restricción que el diagrama pueda mostrar, pero es la más importante de esta tabla.

---

## Contenido y representación vectorial

```mermaid
erDiagram
    DOCUMENTO_VERSION ||--o{ CHUNK : "documento_version_id"
    MODELO_EMBEDDING ||--o{ CHUNK : "modelo_embedding_id"

    MODELO_EMBEDDING {
        smallint id PK "identidad"
        text nombre UK
        integer dimension
        text metrica
        boolean activo
        date vigente_desde
    }
    CHUNK {
        bigint id PK "identidad"
        bigint documento_version_id FK "UK"
        integer orden UK
        text texto
        integer tokens
        smallint modelo_embedding_id FK
        vector_1024 embedding "nulo"
        tsvector tsv "generada, nulo"
        jsonb metadatos
        timestamptz creado_en
    }
    DOCUMENTO_VERSION { }
```

**El fragmento cuelga de la versión, no del documento** (decisión D2). De esa pertenencia hereda su
nivel de confidencialidad y su vigencia: `chunk` no tiene columna de nivel, y esa ausencia es
deliberada. Un nivel propio en el fragmento sería un dato duplicado que puede quedar desalineado del
documento, y el día que se desalinee, la desalineación es una fuga.

**`tsv` es una columna generada.** No se inserta: el motor la deriva de `texto`, de modo que no
puede desincronizarse de él.

**La dimensión está en el tipo.** `vector_1024` no es una anotación del diagrama: es el tipo de la
columna. Cambiar de modelo de embeddings conservando la dimensión es una revectorización; cambiar de
dimensión exige una columna nueva. Que sea el tipo el que lo impone obliga a que ese cambio sea una
decisión y no un efecto colateral.

---

## Uso del sistema

```mermaid
erDiagram
    CHUNK ||--o{ RESPUESTA_FUENTE : "chunk_id"
    CONSULTA ||--o| RESPUESTA : "consulta_id, creado_en"
    RESPUESTA ||--o{ FEEDBACK : "respuesta_id, respuesta_creado_en"
    RESPUESTA ||--o{ RESPUESTA_FUENTE : "respuesta_id, creado_en"
    USUARIO ||--o{ CONSULTA : "usuario_id"
    USUARIO ||--o{ FEEDBACK : "usuario_id"

    CONSULTA {
        bigint id PK "identidad"
        bigint usuario_id FK
        text texto
        vector_1024 embedding "nulo"
        smallint modelo_embedding_id FK "nulo"
        integer latencia_ms "nulo"
        timestamptz creado_en PK
    }
    RESPUESTA {
        bigint id PK "identidad"
        bigint consulta_id FK "UK"
        text texto
        text modelo
        integer tokens_entrada "nulo"
        integer tokens_salida "nulo"
        numeric_4_3 confianza "nulo"
        timestamptz creado_en PK "FK, UK"
    }
    RESPUESTA_FUENTE {
        bigint respuesta_id PK "FK, UK"
        bigint chunk_id PK "FK"
        smallint posicion UK
        real puntaje
        timestamptz creado_en PK "FK, UK"
    }
    FEEDBACK {
        bigint id PK "identidad"
        bigint respuesta_id FK "UK"
        timestamptz respuesta_creado_en FK "UK"
        bigint usuario_id FK "UK"
        boolean util
        text comentario "nulo"
        timestamptz creado_en
    }
    USUARIO { }
    CHUNK { }
```

**Las claves foráneas arrastran la fecha.** `respuesta` referencia a `consulta` por
`(consulta_id, creado_en)` y no sólo por el identificador. Hay dos motivos: en una tabla
particionada la clave primaria debe incluir la clave de partición, y arrastrar la fecha garantiza
que padre e hijo caigan en la misma partición.

**`CONSULTA ||--o| RESPUESTA` es la única relación 1:1 del modelo.** El símbolo `o|` lo produce la
restricción `UNIQUE (consulta_id, creado_en)`: una consulta produce a lo sumo una respuesta. Puede
no producir ninguna, y eso no es un caso de error: es una consulta sin cobertura, que es
precisamente lo que la capa analítica busca.

**`respuesta_fuente` responde el requisito central del caso.** Registra qué fragmentos originaron
cada respuesta, con su posición en el ranking y su puntaje. La posición y el puntaje son lo que
permite explicar *por qué* el modelo dijo lo que dijo, y no sólo qué documentos tenía a mano.

---

## Auditoría

```mermaid
erDiagram
    CHUNK |o--o{ LOG_ACCESO : "chunk_id"
    DOCUMENTO |o--o{ LOG_ACCESO : "documento_id"
    USUARIO ||--o{ AUDITORIA : "usuario_id"
    USUARIO ||--o{ DOCUMENTO : "creado_por"
    USUARIO ||--o{ LOG_ACCESO : "usuario_id"

    LOG_ACCESO {
        bigint id PK "identidad"
        bigint usuario_id FK
        bigint documento_id FK "nulo"
        bigint chunk_id FK "nulo"
        text accion
        jsonb contexto
        timestamptz creado_en PK
    }
    AUDITORIA {
        bigint id PK "identidad"
        bigint usuario_id FK
        text entidad
        bigint entidad_id
        text operacion
        jsonb datos_antes "nulo"
        jsonb datos_despues "nulo"
        timestamptz creado_en PK
    }
    USUARIO { }
    DOCUMENTO { }
    CHUNK { }
```

**`auditoria` no tiene clave foránea hacia la entidad que audita.** La identifica por nombre de
tabla (`entidad`) e identificador (`entidad_id`), sin integridad referencial. Es deliberado: el
registro tiene que sobrevivir a la baja de aquello que audita. Con una clave foránea, borrar un
otorgamiento de acceso borraría también la constancia de que existió.

`log_acceso` sí tiene claves foráneas, y ambas admiten nulo: un acceso puede registrarse sobre un
documento, sobre un fragmento o sobre los dos, y una verificación exige que al menos uno esté
informado.

---

## Restricciones que el diagrama no puede mostrar

Un diagrama entidad-relación muestra estructura, no reglas. Estas son las restricciones de
integridad que el DDL declara y que hay que leer en
[`03_tablas.sql`](../../db/estructura/03_tablas.sql):

| Tipo | Ejemplo | Qué garantiza |
|---|---|---|
| Exclusión (`EXCLUDE USING gist`) | `documento_version` | A lo sumo una versión vigente por documento en cada instante (RD2) |
| Verificación de arco exclusivo | `acl_documento` | Exactamente un sujeto por otorgamiento (RD7) |
| Verificación anti-reflexiva | `documento_relacion` | Un documento no se relaciona consigo mismo |
| Verificación de coherencia de fechas | `documento_version`, `acl_documento` | La vigencia no termina antes de empezar |
| Verificación de coherencia de baja | `usuario` | Un usuario inactivo tiene fecha de baja, y uno activo no |
| Unicidad de hash | `documento_version` | El mismo archivo no se ingesta dos veces (RD6) |
| Verificación de formato | `permiso.codigo`, `usuario.email`, `hash_sha256` | Los valores respetan el formato del dominio |
| Tipo enumerado | `estado_documento`, `tipo_relacion_documento` | El conjunto de valores es cerrado |

Tres restricciones del dominio siguen pendientes porque dependen de disparadores que no se
escribieron: RD4 (que un documento derogado no tenga una versión con vigencia abierta), RD5
(ausencia de ciclos en la derogación) y la mitad de RD9 (que los órdenes de los fragmentos de una
versión sean consecutivos, no sólo únicos). Están documentadas en el punto 8.2 del informe.
