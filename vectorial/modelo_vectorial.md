# Modelo de datos vectorial

La consigna pide analizar qué tecnologías aplican al caso y cuáles no. En `nosql/` iría el
análisis de por qué el trabajo no suma otra base; acá va lo otro: **cómo está modelada la parte
vectorial** dentro de PostgreSQL. Qué se vectoriza, qué acompaña a cada vector, cómo se vincula
con el documento del que salió, qué consultas resuelve y qué restricciones de acceso lo alcanzan.

Todos los números de este documento están medidos sobre la base cargada con el conjunto de datos
de ejemplo (46 documentos, 49 versiones, 116 fragmentos), no estimados.

---

## 1. Qué se vectoriza

Dos cosas, y sólo dos:

| Qué | Dónde | Por qué |
|---|---|---|
| El **fragmento** de una versión de documento | `core.chunk.embedding` | Es la unidad de recuperación: lo que se busca y lo que entra al contexto del modelo de lenguaje |
| La **pregunta** del usuario | `core.consulta.embedding` | Para poder agrupar preguntas semánticamente equivalentes y detectar temas sin cobertura |

No se vectoriza el documento entero ni la versión completa. Un documento de este corpus tiene
entre 1.800 y 4.200 caracteres y cubre entre cinco y ocho temas distintos: un único vector para
todo eso es el promedio de ocho cosas, y no se parece a ninguna. La recuperación pide granularidad
menor que el documento, y esa granularidad es el fragmento.

Tampoco se vectoriza el texto de la respuesta generada. La respuesta no se recupera: se produce.
Guardar su vector sería costo sin consulta que lo justifique.

### El fragmento: cómo se corta

Lo hace `etl/chunker.py`, con tres reglas en orden de prioridad:

1. **Una sección no se parte** —salvo que por sí sola supere el máximo—, porque un fragmento que
   arranca a mitad de una oración recupera mal.
2. **Varias secciones cortas consecutivas sí comparten fragmento.** Un fragmento de treinta tokens
   no tiene contexto suficiente para responder nada.
3. **Se solapa** el final de un fragmento con el principio del siguiente, dentro de la misma
   sección, para que una respuesta que vive a caballo del corte no se pierda.

Resultado sobre el corpus: 116 fragmentos, 211 tokens de promedio, ninguno por encima de 330.

---

## 2. Qué acompaña a cada vector

Un vector suelto no sirve para nada: no se puede citar, ni filtrar, ni auditar. Lo que hace útil a
`core.chunk` es todo lo que **no** es el vector.

```
chunk
├── embedding              vector(1024)   la representación semántica
├── tsv                    tsvector       la representación léxica (columna GENERADA)
├── texto                  text           lo que efectivamente entra al contexto del modelo
├── tokens                 integer        para dimensionar el contexto antes de armarlo
├── orden                  integer        posición dentro de la versión
├── metadatos              jsonb          sección, secciones cubiertas, formato de origen
├── modelo_embedding_id    smallint  ───► con qué modelo se produjo este vector
└── documento_version_id   bigint    ───► de qué versión de qué documento salió
```

Tres de esas columnas merecen explicación.

**`tsv` es una columna generada.** No se inserta: PostgreSQL la deriva de `texto` con la
configuración `espanol_unaccent`. Que sea generada y no mantenida por la aplicación significa que
no puede desincronizarse del texto. Es la mitad léxica de la recuperación híbrida, y sin ella la
búsqueda no distingue la Comunicación "A" 7724 de la 7511.

**`modelo_embedding_id` no es un adorno.** Dos vectores producidos por modelos distintos no son
comparables, y sin este dato no hay forma de saberlo ni de planificar una revectorización. Cambiar
de modelo conservando la dimensión es una revectorización; cambiar de dimensión exige una columna
nueva, porque la dimensión está fijada en el tipo (`vector(1024)`) y eso es deliberado: obliga a
que el cambio sea una decisión y no un efecto colateral.

**`metadatos` lleva la sección.** Es lo que permite que una respuesta cite "sección 4 del
procedimiento de conocimiento del cliente" y no el documento entero. Sin eso, la trazabilidad
degrada a una lista de documentos, que es mucho menos de lo que el caso pide.

---

## 3. Cómo se vincula con el documento original

El fragmento cuelga de la **versión**, no del documento:

```
documento  1 ──< N  documento_version  1 ──< N  chunk
```

Es la decisión D2 del informe, y es la que hace posible la auditoría en el tiempo. Si los
fragmentos colgaran del documento, al publicar una versión nueva habría que decidir qué hacer con
los viejos, y se perdería la posibilidad de reconstruir con qué texto exacto se respondió una
consulta de hace seis meses.

El corpus tiene el caso para probarlo: `DOC-CMP-005` tiene tres versiones sucesivas, con sus
ventanas de vigencia sin solaparse. Cada una tiene sus propios fragmentos y sus propios vectores.
Las respuestas citan la versión que regía al momento de responder.

El binario original no está en la base. `documento_version` guarda la URI del *object storage*, el
hash SHA-256 del archivo y el texto extraído. El hash cumple dos funciones: detectar que el mismo
archivo se volvió a subir sin cambios —y evitar re-procesarlo y re-vectorizarlo— y dejar constancia
de integridad para auditoría.

---

## 4. Qué cuesta el vector

Medido sobre los 116 fragmentos cargados:

| | Tamaño | Por fragmento |
|---|---|---|
| Vectores (`embedding`) | 464 kB | 4.100 bytes |
| Texto (`texto`) | 94 kB | ~830 bytes |
| Representación léxica (`tsv`) | 112 kB | ~990 bytes |
| Índice HNSW | 936 kB | ~8.260 bytes |

**El vector ocupa cinco veces más que el texto que representa, y el índice ocupa el doble que los
vectores.** Un `vector(1024)` son 1024 × 4 bytes de punto flotante más cabecera: 4.100 bytes fijos,
sin importar si el fragmento tiene cien palabras o trescientas.

Es el dato que hay que tener a mano al dimensionar. Extrapolado al volumen que el informe estima
para el caso —del orden de un millón de fragmentos— son unos 4 GB de vectores más unos 8 GB de
índice, contra unos 800 MB de texto. La parte vectorial es el 90% del almacenamiento del sistema.

Existen mecanismos para bajarlo (cuantización escalar o binaria, que pgvector soporta con `halfvec`
y con índices sobre expresiones), a costa de precisión. No se aplican acá porque al volumen del
caso no hacen falta, pero es la primera palanca a mirar si el volumen crece.

---

## 5. Qué consultas por similitud resuelve

| Consulta | Cómo | Dónde está |
|---|---|---|
| Fragmentos más parecidos a una pregunta | `embedding <=> $1` con índice HNSW | `db/consultas/01`, `02` |
| Recuperación híbrida: semántica + término exacto | HNSW + GIN sobre `tsv`, fusionados por RRF | `db/consultas/02` |
| Preguntas equivalentes formuladas distinto | `consulta.embedding` entre sí | insumo de la vista de cobertura |

La métrica es **coseno** (`<=>`), consistente con `modelo_embedding.metrica` y con la clase de
operador del índice (`vector_cosine_ops`). Tienen que coincidir las tres: un índice construido con
una métrica no se usa para una consulta que pide otra, y el síntoma es que la consulta funciona
pero lenta, que es la peor forma de enterarse.

Los vectores se guardan **normalizados a longitud 1** (`etl/embeddings.py`). Con vectores unitarios
la distancia coseno es una función monótona del producto interno y las comparaciones son estables.

---

## 6. Qué restricciones de acceso lo alcanzan

Acá es donde el modelo vectorial de este trabajo se aparta del modelo vectorial habitual.

`chunk` **no tiene clasificación propia**. No hay una columna `nivel` en el fragmento. El fragmento
hereda su nivel de confidencialidad y su vigencia de la versión de la que cuelga, y la única vía
para conocerlos es esa pertenencia. Es deliberado: un nivel propio en el fragmento sería un dato
duplicado que puede quedar desalineado del documento, y el día que se desalinee, la desalineación
es una fuga.

Sobre `chunk` hay una política de seguridad por fila (`db/estructura/05_rls.sql`) que resuelve el
documento a través de la versión y aplica la regla de acceso. El efecto es el que el caso necesita:

> **El recuperador semántico puede ser ciego a los permisos porque el motor no lo es.**

La consulta de recuperación no lleva ningún `WHERE` de permisos. No puede olvidárselo, porque no lo
escribe.

### El precio: HNSW filtra después de buscar

Es la limitación más importante de este diseño y conviene enunciarla sin adornos, porque está
medida:

Un índice HNSW es **aproximado**. No recorre todos los vectores: navega un grafo y devuelve un
conjunto de candidatos cuyo tamaño lo fija `hnsw.ef_search` (40 por omisión). La política de
seguridad se aplica **sobre ese conjunto ya recortado**, no antes. Si el usuario sólo puede ver una
fracción de los fragmentos, buena parte de los candidatos se descarta y el `LIMIT` no se llena.

Medido sobre la base cargada, con un usuario de habilitación `publico` que puede ver 28 de los 116
fragmentos, pidiendo los 10 más relevantes:

| `hnsw.ef_search` | Filas devueltas (se pidieron 10) |
|---|---|
| 10 | **1** |
| 40 (valor por omisión) | **7** |
| 200 | 10 |

Con la configuración por omisión el usuario recibe 7 fragmentos en lugar de 10. **No porque sólo
haya 7 relevantes que pueda ver —hay 28 accesibles— sino porque el índice devolvió 40 candidatos y
sólo 7 le estaban permitidos.** La pérdida es silenciosa: la consulta no falla, devuelve menos.

Esto no compromete la seguridad —el error es siempre hacia el lado de mostrar de menos, nunca de
más, que es el lado correcto para fallar— pero sí la calidad de la recuperación, y afecta
desproporcionadamente a los usuarios con menos permisos, que son la mayoría.

Mitigaciones, en orden de preferencia:

1. **Subir `ef_search` en la sesión de recuperación**, en función de qué fracción del corpus ve el
   usuario. Es la más simple y la que se recomienda acá. Cuesta latencia, no correctitud.
2. **Sobre-pedir y recortar**: pedir k × 4 al índice y quedarse con los primeros k que sobrevivan al
   filtro. Es lo mismo que lo anterior por otra vía.
3. **Índices parciales por nivel de confidencialidad**, de modo que el filtro más grueso se aplique
   antes del índice y no después. Sirve cuando los niveles particionan bien la población; acá no
   resuelve los otorgamientos nominales, que son por usuario.

Ninguna de las tres se implementa en este trabajo: la implementación mínima no lo exige y al
volumen del caso el planificador resuelve la consulta con un recorrido secuencial —116 filas— sin
tocar el índice. Queda documentado como lo que es: **el costo concreto de haber puesto el control de
acceso dentro del motor**, que es la decisión central del diseño y que sigue siendo la correcta.

---

## 7. Por qué esto vive en PostgreSQL y no en un motor vectorial dedicado

La sección 6 es el argumento entero.

Qdrant, Milvus o Pinecone resuelven la búsqueda por similitud mejor que pgvector a gran escala, con
filtrado por metadatos incluido. Pero el filtro que este caso necesita no es por metadatos: es la
regla de acceso completa —nivel de habilitación del usuario, otorgamientos por área, por rol y
nominales, cada uno con su ventana de vigencia— que se resuelve contra cinco tablas relacionales.

Sacar los vectores de PostgreSQL obliga a una de dos cosas:

- **Replicar la ACL en el motor vectorial** y mantenerla sincronizada. Cada desincronización es una
  fuga, y las desincronizaciones no avisan.
- **Filtrar en la aplicación** después de recuperar. Es exactamente el modo de falla que el diseño
  entero existe para evitar: cualquier consulta que se olvide el filtro devuelve fragmentos
  prohibidos, y el modelo de lenguaje redacta con ellos.

A eso se suma que perder la transaccionalidad entre el catálogo documental y los vectores introduce
un estado que no existe hoy: un fragmento vectorizado de un documento que ya se derogó, o un
documento cuyos vectores todavía no se escribieron.

El volumen del caso —del orden de un millón de fragmentos— entra cómodo en pgvector con HNSW. El
umbral a partir del cual la conversación cambia son las decenas de millones de vectores con alta
concurrencia, y llegado ese punto la pregunta correcta no es "¿qué motor vectorial usamos?" sino
"¿cómo movemos la evaluación de la regla de acceso a un lugar donde el motor vectorial pueda
aplicarla antes de buscar y no después?".
