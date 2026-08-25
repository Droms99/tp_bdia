# Informe técnico

**Trabajo Práctico Integrador — Bases de Datos para IA**
**Caso 1 — Sistema RAG para consulta de documentación técnica**

Integrantes: Martin Birman · Gonzalo Castro · Hernando Scheidl

---

## Contenido

1. [Descripción del caso de uso](#1-descripción-del-caso-de-uso)
2. [Relevamiento de datos necesarios](#2-relevamiento-de-datos-necesarios)
3. [Clasificación de los datos](#3-clasificación-de-los-datos)
4. [Modelo conceptual](#4-modelo-conceptual)
5. [Modelo de implementación](#5-modelo-de-implementación)
6. [Normalización, desnormalización y embebido](#6-normalización-desnormalización-y-embebido)
7. [Selección y justificación de la tecnología](#7-selección-y-justificación-de-la-tecnología)
8. [Implementación mínima](#8-implementación-mínima)
9. Datos de ejemplo
10. Consultas representativas
11. Datos semiestructurados, no estructurados y vectoriales
12. [Arquitectura de datos](#12-arquitectura-de-datos)
13. [Seguridad, permisos y aislamiento](#13-seguridad-permisos-y-aislamiento)
14. [Escalabilidad y rendimiento](#14-escalabilidad-y-rendimiento)
15. Conclusiones

---

## 1. Descripción del caso de uso

### 1.1 El problema

Una organización acumula, a lo largo de los años, una cantidad considerable de documentación
técnica: manuales de sistemas, instructivos operativos, políticas internas, procedimientos,
normas que le impone un regulador, preguntas frecuentes y documentos que ya no están vigentes
pero que debe conservar. Esa documentación está dispersa en distintos repositorios, escrita en
formatos heterogéneos y versionada de manera despareja.

Encontrar una respuesta puntual implica, hoy, una de dos cosas: buscar a mano entre archivos, o
preguntarle a alguien con años en la organización. Ninguna de las dos escala, y ambas producen
el mismo conjunto de consecuencias:

- **Tiempo perdido** en cada consulta, multiplicado por la cantidad de personas que la hacen.
- **Respuestas inconsistentes**: dos personas contestan distinto la misma pregunta según qué
  documento encontraron primero.
- **Conocimiento concentrado** en pocas personas, que se va con ellas.
- **Uso de documentación derogada**: se responde con un procedimiento que fue reemplazado,
  simplemente porque quien lo consultó no tenía forma de saber que ya no rige.

La solución propuesta es un sistema RAG (*Retrieval-Augmented Generation*): recupera de una base
los fragmentos de documentación más relevantes para una pregunta escrita en lenguaje natural y se
los entrega a un modelo de lenguaje, que redacta la respuesta **usando solamente ese material** y
citando de dónde salió cada afirmación.

Esto define dos flujos de datos con exigencias muy distintas. La **ingesta** es un proceso de
escritura, poco frecuente y controlado: se carga un documento, se lo clasifica, se lo parte en
fragmentos, se representa cada fragmento como un vector numérico y se almacena todo. La
**consulta** es un proceso de lectura, frecuente y sensible a la latencia: se convierte la
pregunta al mismo espacio vectorial, se recuperan los fragmentos más cercanos y se registra qué
se recuperó y qué se respondió.

### 1.2 Contexto: una entidad financiera regulada

El caso se ambienta en un banco de tamaño medio sujeto a regulación, porque allí conviven todos
los tipos de documentación que el sistema debe manejar, cada uno con una exigencia distinta.

| Tipo de documentación | Característica que aporta al caso |
|---|---|
| Normativa externa del regulador (BCRA) | Cambia con frecuencia; las versiones viejas quedan derogadas pero deben conservarse |
| Políticas internas (riesgo crediticio, prevención de lavado, seguridad de la información) | Acceso restringido por área y por nivel de confidencialidad |
| Procedimientos operativos de sucursal y de *back office* | Alto volumen de consulta, muchas versiones, público amplio |
| Manuales técnicos del core bancario y sistemas satélite | Contenido sensible desde el punto de vista de la seguridad informática |
| Preguntas frecuentes | Conocimiento hoy informal, respondido a mano por gente con experiencia |
| Informes de investigación (fraude interno, casos reportados) | El caso extremo de acceso restringido |
| Documentación histórica derogada | Debe conservarse por obligación regulatoria y **no debe usarse para responder** |

En una organización así, que un analista de sucursal no pueda leer el informe de una
investigación de fraude interno no necesita justificación, y contestar con un procedimiento
derogado puede constituir un incumplimiento regulatorio.

Para poder estimar volúmenes y justificar decisiones de escalabilidad, se toma como referencia
una organización de aproximadamente 4.000 empleados, de los cuales unos 1.500 son usuarios
efectivos del sistema, distribuidos en 6 áreas, con del orden de 20.000 documentos vigentes y
unas 45.000 versiones acumuladas contando el histórico. Son un supuesto de trabajo y se retoman
en 2.4 y en 14.

### 1.3 Alcance del trabajo

El objeto de este trabajo es **la solución de datos**. No se entrena ni se ajusta ningún modelo,
y no se construye la aplicación ni su interfaz.

| Dentro del alcance | Fuera del alcance |
|---|---|
| Modelo conceptual, lógico y físico de los datos | Entrenamiento o ajuste fino de modelos |
| Estrategia de clasificación y de metadatos | Desarrollo de la interfaz de usuario |
| Representación vectorial del contenido y su almacenamiento | Elección y evaluación del modelo de lenguaje |
| Control de acceso, auditoría y trazabilidad | Infraestructura de despliegue productivo |
| Consultas de recuperación y de análisis | Ingeniería de *prompts* y calidad de la redacción |

El modelo de lenguaje se trata como una **caja negra**: recibe una pregunta y un conjunto de
fragmentos, y devuelve texto. La frontera con la solución de datos queda fijada así:

1. La base entrega al modelo **únicamente** fragmentos que el usuario que pregunta está
   autorizado a ver y que pertenecen a documentación vigente.
2. El modelo redacta con ese material.
3. La base registra qué fragmentos se entregaron, con qué puntaje y en qué orden, junto con la
   respuesta producida.

### 1.4 Usuarios

El sistema tiene dos clases de usuario con necesidades opuestas: quienes **consultan** y quienes
**mantienen** la documentación. En la tabla, la columna de lo que cada perfil no debe ver es la
que define el problema central del caso.

| Perfil | Qué consulta | Qué no debe poder ver |
|---|---|---|
| Analista de sucursal (Operaciones) | Procedimientos operativos, instructivos de atención, preguntas frecuentes | Manuales técnicos del core, informes de investigación, políticas de nivel restringido |
| Oficial de riesgo crediticio (Riesgos) | Políticas de riesgo, normativa del regulador, criterios de otorgamiento | Informes de investigación de fraude, documentación técnica de sistemas |
| Analista de prevención de lavado (Compliance) | Normativa, políticas de prevención, procedimientos de reporte, informes de casos de su alcance | Documentación técnica de sistemas, políticas de otras áreas de nivel confidencial |
| Administrador de sistemas (Tecnología) | Manuales técnicos, guías de configuración, procedimientos de contingencia | Informes de investigación, documentación de negocio de nivel restringido |
| Auditor interno (Auditoría Interna) | Prácticamente todo el corpus, **incluida la documentación derogada** y los registros de auditoría del propio sistema | Restricciones mínimas, definidas caso por caso |
| Abogado (Legales) | Normativa, contratos marco, dictámenes, políticas | Documentación técnica de sistemas |
| Curador documental | No consulta para obtener respuestas: carga, clasifica, versiona, publica y deroga documentos, y asigna sus permisos | — |

De los perfiles se desprenden dos observaciones que condicionan el modelo de datos:

**El permiso no es un atributo del usuario ni del documento, sino de la relación entre ambos.**
Un mismo informe de investigación es visible para Compliance y para Auditoría Interna, e
invisible para el resto; un mismo manual técnico es visible para Tecnología y no para Riesgos.
No alcanza con un nivel de habilitación por usuario ni con una etiqueta por documento: hace
falta una entidad que exprese explícitamente el otorgamiento, y que pueda hacerlo a nivel de
área, de rol o de usuario individual.

**La vigencia y el permiso son dos ejes independientes.** El auditor interno es el caso que lo
demuestra: necesita consultar deliberadamente documentación derogada, que para todos los demás
perfiles no debe alimentar ninguna respuesta. Un documento derogado no es un documento
inaccesible, es un documento excluido de la recuperación por defecto. Resolver la vigencia con
las mismas reglas que el acceso haría imposible el caso de uso de auditoría, que es justamente
el que justifica conservar el histórico.

### 1.5 Procesos que soporta la solución

**P1 — Ingesta y normalización.** El curador carga un archivo y declara sus metadatos. Se
calcula el hash SHA-256 del binario, se lo deposita en el almacenamiento de objetos y se extrae
su texto plano. Si el hash ya existe en la base, el proceso se detiene: el mismo archivo no se
vuelve a procesar ni a vectorizar. Produce el registro de la versión con su texto extraído.

**P2 — Clasificación y asignación de permisos.** Se asigna tipo de documento, área propietaria,
nivel de confidencialidad, etiquetas y los metadatos propios del tipo, que varían de un tipo a
otro. Se declaran los otorgamientos de acceso. Este paso es el que determina quién podrá ver el
contenido: un error acá es una fuga que ninguna capa posterior corrige.

**P3 — Versionado y ciclo de vida.** Una versión nueva no reemplaza a la anterior: se agrega. Se
registran la vigencia desde y hasta, el estado del documento y las relaciones con otros
documentos (deroga, reemplaza, complementa, referencia). Las versiones anteriores se conservan
por obligación regulatoria y quedan excluidas de la recuperación ordinaria.

**P4 — Fragmentación y vectorización.** El texto de la versión se parte en fragmentos de unos
cientos de palabras, con solapamiento entre fragmentos consecutivos y respetando los límites de
sección para no cortar una idea al medio. De cada fragmento se obtienen su representación
vectorial y su representación para búsqueda de texto completo en español. Los fragmentos se
asocian a la versión, no al documento.

**P5 — Consulta y generación.** La pregunta del usuario se convierte al mismo espacio vectorial.
Se recuperan los fragmentos candidatos combinando búsqueda vectorial y búsqueda de texto
completo, y ese conjunto se restringe a lo que el usuario puede ver y a lo que está vigente. Los
fragmentos resultantes se entregan al modelo, que redacta la respuesta. Se registran la
pregunta, la respuesta y las fuentes efectivamente utilizadas.

**La restricción por permisos no la aplica el proceso de consulta.** La aplica el motor de base
de datos, por debajo, de manera que ninguna consulta pueda omitirla. El mecanismo se desarrolla
en el punto 13.

**P6 — Realimentación.** El usuario indica si la respuesta le resultó útil y puede dejar un
comentario. Es el insumo para detectar documentación deficiente o faltante.

**P7 — Auditoría.** Cada acceso a un documento, cada cambio de permisos y cada cambio de estado
documental se registra de manera permanente y no modificable.

**P8 — Análisis de uso.** Sobre los registros acumulados se calculan indicadores: qué se
consulta, qué documentación se cita más, qué preguntas no encuentran respuesta.

Todo dato que la solución almacene tiene un proceso que lo produce y al menos uno que lo
consume:

| Proceso | Datos que produce | Datos que consume |
|---|---|---|
| P1 Ingesta | Documento, versión, hash, URI, texto extraído | Archivo original, metadatos declarados |
| P2 Clasificación | Tipo, área, confidencialidad, etiquetas, metadatos variables, otorgamientos de acceso | Catálogos, estructura organizativa |
| P3 Ciclo de vida | Estado, ventana de vigencia, relaciones entre documentos | Versiones previas |
| P4 Fragmentación | Fragmentos, vectores, índice de texto completo | Texto extraído de la versión |
| P5 Consulta | Consulta, respuesta, fuentes citadas | Fragmentos, permisos, vigencia |
| P6 Realimentación | Valoración y comentario | Respuesta |
| P7 Auditoría | Registro de accesos y de cambios | Todos los anteriores |
| P8 Análisis | Indicadores agregados | Consultas, respuestas, fuentes, documentos |

### 1.6 Información a gestionar

De los procesos anteriores surgen seis familias de información, que el punto 2 desarrolla en
detalle: la **estructura organizativa y de permisos**; el **catálogo documental** con sus
versiones y relaciones; el **contenido fragmentado** y su representación vectorial; el **uso del
sistema** (consultas, respuestas, fuentes citadas y realimentación); los **registros de
auditoría**; y los **datos derivados** de la capa analítica.

### 1.7 Riesgos sobre los datos

**R1 — Fuga de información por recuperación.** Es el riesgo central del caso. Una búsqueda por
similitud es ciega al permiso: si un analista de sucursal pregunta cuál es el procedimiento ante
un caso de fraude interno, el motor va a encontrar como más relevante, con toda razón, el manual
de investigación de fraude, que ese usuario no tiene derecho a leer. Y a diferencia de una
consulta convencional, acá el modelo **redacta con ese contenido**: el daño no requiere que el
usuario vea el documento, le alcanza con que el fragmento haya entrado al contexto del modelo.

**R2 — Respuesta construida sobre documentación desactualizada.** Se contesta con un
procedimiento derogado o con una versión anterior de una norma. En una entidad regulada esto
puede derivar en un incumplimiento. El riesgo se agrava porque la documentación derogada
**sigue existiendo en la base** por obligación de conservación: no se puede eliminar, hay que
excluirla explícitamente de la recuperación.

**R3 — Respuesta no trazable.** No poder reconstruir, meses después, con qué material se produjo
una respuesta determinada. Sin esa reconstrucción no hay forma de auditar el sistema, ni de
responder ante un cuestionamiento sobre una recomendación que dio.

**R4 — Reingesta y duplicación de contenido.** El mismo archivo cargado dos veces genera
fragmentos duplicados. El costo de reprocesar es lo de menos: el problema real es que el mismo
pasaje aparece varias veces entre los mejores resultados y desplaza a otras fuentes legítimas,
degradando la calidad de la respuesta de una forma difícil de diagnosticar.

**R5 — Heterogeneidad en la representación vectorial.** Los vectores producidos por modelos
distintos no son comparables entre sí, y tampoco lo son los de dimensiones distintas. Si al
cambiar de modelo se mezclan vectores viejos y nuevos en la misma colección, la recuperación se
degrada de manera silenciosa: no falla, simplemente empieza a traer resultados peores. Obliga a
registrar con qué modelo y con qué dimensión fue generado cada vector.

**R6 — Otorgamientos de acceso demasiado amplios o vencidos.** Un permiso concedido de manera
transitoria que nadie revoca, o un otorgamiento a nivel de área cuando correspondía a nivel de
usuario. Es la forma más común de que R1 ocurra sin que ningún mecanismo técnico falle.

**R7 — Datos personales en el texto de las preguntas.** El usuario escribe en su consulta el
número de documento de un cliente o el nombre de un empleado. La tabla de consultas, que a
primera vista es un registro de uso, pasa a contener datos personales y debe tratarse en
consecuencia.

**R8 — Pérdida de contexto de confidencialidad en los datos derivados.** Un fragmento hereda la
confidencialidad del documento del que proviene. Si su texto se copia a una caché, a una vista
materializada o a una exportación analítica, esa protección no viaja con él. Cualquier
estructura derivada que contenga texto de fragmentos queda sujeta al mismo régimen de acceso, o
directamente no debe contener texto.

| Riesgo | Se ataca con | Se desarrolla en |
|---|---|---|
| R1 Fuga por recuperación | Control de acceso resuelto dentro del motor de base de datos | Puntos 5 y 13 |
| R2 Documentación desactualizada | Versionado, ventana de vigencia y estado como criterio de recuperación | Puntos 4, 5 y 10 |
| R3 Falta de trazabilidad | Registro de las fuentes de cada respuesta y auditoría permanente | Puntos 5, 10 y 13 |
| R4 Duplicación por reingesta | Hash SHA-256 del archivo como control de identidad | Puntos 2 y 8 |
| R5 Vectores heterogéneos | Registro del modelo y la dimensión junto a cada vector | Puntos 8 y 11 |
| R6 Permisos amplios o vencidos | Otorgamientos con ventana de vigencia y auditoría de cambios de permisos | Punto 13 |
| R7 Datos personales en consultas | Clasificación de la información y política de retención | Puntos 3 y 13 |
| R8 Derivados sin protección | Restricción de qué puede contener la capa analítica | Puntos 12 y 13 |

### 1.8 Decisiones de diseño

Las decisiones que siguen se toman acá porque se desprenden del análisis del caso y no de la
tecnología elegida.

**D1 — El control de acceso vive dentro del motor de base de datos, no en la aplicación.** Si el
filtro de permisos lo aplicara el código que consulta, bastaría una consulta mal escrita, un
recuperador nuevo o un script de análisis para producir una fuga. Al resolverlo en el motor, el
sistema no puede devolver una fila prohibida **ni aunque la consulta esté mal escrita**. El
recuperador puede ser ciego al permiso (R1) porque el motor no lo es.

**D2 — Los fragmentos pertenecen a la versión del documento, no al documento.** Si colgaran del
documento, al publicar una versión nueva habría que decidir qué hacer con los fragmentos
anteriores, y en cualquiera de los caminos posibles se pierde la capacidad de reconstruir con
qué texto exacto se respondió una consulta de hace seis meses. Es la decisión que permite trazar
las respuestas (R3) y conservar el histórico sin contaminar la recuperación.

**D3 — La vigencia es un criterio de recuperación, y es independiente del permiso.** El estado
del documento y su ventana de vigencia participan de la búsqueda, no son un dato informativo. Y
como se vio en 1.4, se modelan como un eje separado del acceso, para que la consulta explícita
sobre el histórico siga siendo posible para quien corresponda.

**D4 — Cada respuesta guarda exactamente qué fragmentos la originaron.** No basta con guardar
qué documentos se consultaron: se registra el fragmento, su puntaje y su posición en el ranking.
Esa granularidad es la que permite, más adelante, explicar una respuesta y no solo listar
fuentes.

**D5 — El archivo original no se almacena en la base.** Se guardan la ruta al almacenamiento de
objetos, el hash SHA-256 y el texto extraído. El hash cumple dos funciones: detectar la
reingesta de un archivo sin cambios (R4) y dejar constancia de integridad para auditoría.

**D6 — Los metadatos que varían entre tipos de documento se modelan como un documento
estructurado dentro de la fila.** Una norma externa tiene número de comunicación y organismo
emisor; un manual de sistema tiene versión de producto y ambiente; una FAQ no tiene ninguno de
los dos. Modelar eso con una tabla de atributos genéricos degrada las consultas y la integridad;
modelarlo con una columna por atributo posible produce una tabla mayormente vacía.

| Decisión | Riesgo que ataca | Se desarrolla en |
|---|---|---|
| D1 Control de acceso en el motor | R1, R6 | Puntos 5, 7 y 13 |
| D2 Fragmentos por versión | R2, R3 | Puntos 4, 5 y 6 |
| D3 Vigencia como criterio de recuperación | R2 | Puntos 4 y 10 |
| D4 Fuentes por respuesta | R3 | Puntos 5, 10 y 13 |
| D5 Binario fuera de la base | R4 | Puntos 2, 7 y 11 |
| D6 Metadatos variables estructurados | — | Puntos 5, 6 y 11 |

---

## 2. Relevamiento de datos necesarios

Este punto identifica **qué información debe almacenar y qué debe poder consultar** la solución.
El relevamiento se hizo por proceso y se controló después contra los riesgos de 1.7, para
verificar que ninguno quedara sin datos que permitan mitigarlo.

Los nombres son los que después toman las entidades del modelo conceptual (punto 4).

### 2.1 Datos por dominio

#### A. Estructura organizativa y control de acceso

Es el dominio que habilita la decisión D1. La observación de 1.4 —que el permiso es una
propiedad de la relación entre usuario y documento— obliga a que el otorgamiento sea una entidad
propia y no un atributo, y a que pueda expresarse en tres granularidades: por área, por rol o
por usuario individual.

| Dato | Qué se guarda | Origen | Frecuencia de cambio | Criticidad |
|---|---|---|---|---|
| `area` | Unidades organizativas: Riesgos, Compliance, Tecnología, Operaciones, Legales, Auditoría Interna | Estructura de la organización | Muy baja | Media |
| `usuario` | Identidad, área de pertenencia, estado de alta o baja | Sistema de identidad corporativo | Baja | Alta (datos personales) |
| `rol` | Funciones que agrupan permisos: consultor, curador, auditor, administrador | Definición del proyecto | Muy baja | Alta |
| `permiso`, `rol_permiso` | Acciones habilitadas por rol sobre el sistema | Definición del proyecto | Muy baja | Alta |
| `nivel_confidencialidad` | Escala ordenada: público, interno, confidencial, restringido | Política de seguridad de la información | Nula | Alta |
| `acl_documento` | Otorgamiento de acceso a un documento, por área, rol o usuario, con su ventana de vigencia | Curador documental (P2) | Media | **Máxima** |

La ventana de vigencia en `acl_documento` es una incorporación de este relevamiento respecto del
modelo preliminar, y responde a R6: un permiso otorgado de manera transitoria caduca solo si
tiene una fecha de fin registrada.

#### B. Catálogo documental, versiones y relaciones

| Dato | Qué se guarda | Origen | Frecuencia de cambio | Criticidad |
|---|---|---|---|---|
| `tipo_documento` | Norma externa, política interna, procedimiento, instructivo, manual de sistema, FAQ, documento histórico | Definición del proyecto | Muy baja | Media |
| `documento` | Título, tipo, área propietaria, nivel de confidencialidad, estado, metadatos variables según el tipo | Curador (P1, P2) | Media | Alta |
| `documento_version` | Número de versión, vigencia desde y hasta, hash SHA-256, URI del original, texto extraído | P1 y P3 | Baja por documento, alta en conjunto | Alta |
| `documento_relacion` | Vínculo dirigido entre documentos: deroga, reemplaza, complementa, referencia | Curador (P3) | Baja | Alta |
| `etiqueta`, `documento_etiqueta` | Vocabulario transversal a las áreas | Curador (P2) | Media | Baja |

El estado del documento (borrador, vigente, obsoleto, derogado) y la ventana de vigencia de la
versión son los dos datos que hacen operativa la decisión D3. Las relaciones entre documentos
forman un grafo dirigido —una norma deroga a otra, que a su vez había reemplazado a una
tercera— que hay que poder recorrer en profundidad para responder desde cuándo rige lo que hoy
está vigente.

#### C. Contenido, fragmentos y representación vectorial

| Dato | Qué se guarda | Origen | Frecuencia de cambio | Criticidad |
|---|---|---|---|---|
| Texto extraído | Contenido completo de la versión, en texto plano, sobre `documento_version` | P1 | Inmutable una vez creado | Alta |
| `chunk` | Fragmento de una versión: orden, texto, cantidad de tokens, representación vectorial, representación para búsqueda de texto completo, metadatos de posición (sección, título) | P4 | Inmutable una vez creado | **Máxima** |
| `modelo_embedding` | Identificación del modelo con el que se vectorizó, su dimensión y desde cuándo se usa | P4 | Muy baja | Alta |

`chunk` es la entidad de mayor criticidad del modelo: es la unidad que se recupera, la que entra
al contexto del modelo de lenguaje y, por lo tanto, la que puede filtrar información. Es también
la de mayor volumen. Cada fragmento necesita conocer a qué versión pertenece, no solo para poder
citarlo, sino porque de esa pertenencia se deriva su nivel de confidencialidad y su vigencia: el
fragmento no lleva permisos propios, los hereda.

`modelo_embedding` no figuraba en el modelo preliminar y se agrega por R5. Sin ese registro no
hay manera de saber si dos vectores de la base son comparables, ni de planificar una
revectorización.

Los metadatos de posición permiten citar «sección 4.2 del procedimiento» y no solo el documento
entero.

#### D. Uso del sistema

| Dato | Qué se guarda | Origen | Frecuencia de cambio | Criticidad |
|---|---|---|---|---|
| `consulta` | Usuario que pregunta, texto de la pregunta, representación vectorial de la pregunta, momento, latencia | P5 | Alta, solo inserciones | Alta (posibles datos personales, R7) |
| `respuesta` | Texto generado, modelo utilizado, tokens consumidos, indicador de confianza | P5 | Alta, solo inserciones | Media |
| `respuesta_fuente` | Vínculo entre una respuesta y cada fragmento utilizado, con su puntaje y su posición en el ranking | P5 | Muy alta, solo inserciones | **Máxima** |
| `feedback` | Valoración de utilidad y comentario libre | P6 | Media | Media |

`respuesta_fuente` es la entidad que responde directamente al requisito de **registrar qué
documentos se usaron para construir cada respuesta**. Guarda el fragmento y no el documento (D4)
porque la unidad que efectivamente alimentó al modelo es el fragmento; el documento y su versión
se alcanzan desde ahí.

Guardar la representación vectorial de la pregunta permite agrupar consultas semánticamente
equivalentes y detectar temas sin cobertura documental, a costa de aumentar el tamaño de una
tabla que ya crece rápido. El costo se retoma en el punto 14.

#### E. Auditoría

| Dato | Qué se guarda | Origen | Frecuencia de cambio | Criticidad |
|---|---|---|---|---|
| `log_acceso` | Quién accedió a qué documento o fragmento, cuándo y en qué contexto | P7 | Muy alta, solo inserciones | Alta |
| `auditoria` | Cambios sobre datos sensibles: alta y baja de permisos, cambios de estado documental, cambios de clasificación | P7 | Media, solo inserciones | **Máxima** |

Ambas estructuras son de solo inserción: no se actualizan ni se borran. Un registro de auditoría
modificable no sirve como registro de auditoría. Son, además, las tablas de mayor crecimiento
del sistema junto con `respuesta_fuente`.

#### F. Datos derivados de la capa analítica

No son datos nuevos: son agregaciones precalculadas sobre los anteriores. Se relevan acá porque
determinan qué información hay que conservar y con qué granularidad.

| Indicador | Qué responde | Datos que agrega |
|---|---|---|
| Documentos más citados como fuente | Dónde está el conocimiento que la organización consulta | `respuesta_fuente`, `documento` |
| Consultas sin cobertura | Qué falta documentar: preguntas que no recuperaron nada relevante | `consulta`, `respuesta_fuente`, `feedback` |
| Uso por área y por tipo de documento | Quién consulta qué | `consulta`, `usuario`, `area`, `documento` |
| Antigüedad de la documentación consultada | Qué documentación vieja se sigue usando y habría que revisar | `respuesta_fuente`, `documento_version` |

Por R8, estas estructuras derivadas contienen identificadores y magnitudes agregadas, **no texto
de fragmentos**: el texto no puede salir del ámbito donde está protegido.

### 2.2 Datos que la solución debe poder consultar

El relevamiento incluye los patrones de acceso, porque son los que justifican qué se almacena y
cómo. Cada pregunta se responde con los datos identificados en 2.1.

| Pregunta que el sistema debe poder responder | Datos que la habilitan |
|---|---|
| ¿Qué fragmentos vigentes y autorizados para *este* usuario responden mejor a esta pregunta? | `chunk`, `acl_documento`, estado y vigencia de `documento` y `documento_version` |
| ¿Qué dice la normativa sobre un término exacto, por ejemplo una comunicación identificada por su número? | Representación de texto completo del fragmento, metadatos del documento |
| ¿Qué fuentes respaldaron esta respuesta, y de qué versión de qué documento provenían? | `respuesta_fuente`, `chunk`, `documento_version` |
| ¿La misma pregunta, hecha por dos usuarios distintos, devuelve lo mismo? | `acl_documento`, identidad del usuario en la sesión |
| ¿Cuál es la cadena de derogaciones de este documento hasta la versión que hoy rige? | `documento_relacion`, recorrido en profundidad |
| ¿Qué documentación está por vencer o quedó obsoleta y se sigue consultando? | `documento_version`, `respuesta_fuente` |
| ¿Qué preguntas no encontraron respuesta satisfactoria? | `consulta`, `respuesta_fuente`, `feedback` |
| ¿Qué consulta cada área y con qué frecuencia? | `consulta`, `usuario`, `area` |
| ¿Quién accedió a este documento confidencial en los últimos noventa días? | `log_acceso` |
| ¿Quién otorgó este permiso, cuándo, y sobre qué documento? | `auditoria`, `acl_documento` |
| ¿Este archivo ya fue cargado antes? | Hash SHA-256 en `documento_version` |
| ¿Qué documentos tienen un metadato específico de su tipo, por ejemplo el organismo emisor? | Metadatos variables de `documento` |

Las tres primeras y la quinta son del camino crítico: se ejecutan en cada pregunta y su latencia
es la latencia percibida del sistema. Las demás son de análisis o de auditoría, con exigencias
mucho más laxas. La distinción determina qué se indexa y qué se precalcula (punto 14).

### 2.3 Datos que deliberadamente quedan fuera de la base

| Dato | Dónde vive | Por qué |
|---|---|---|
| Archivo original (PDF, ofimática) | Almacenamiento de objetos; en la base, URI + hash + texto extraído | Ocupa mucho, no se consulta por su contenido binario y no aporta a la recuperación |
| Credenciales de los usuarios | Sistema de identidad corporativo | La solución consume identidades, no las administra; guardar contraseñas sería asumir un riesgo ajeno al caso |
| Pesos y parámetros del modelo de lenguaje | Fuera del alcance (1.3) | El modelo es una caja negra |
| Contenido de las respuestas descartadas por el usuario antes de enviarlas | No se registra | No hay proceso que lo consuma |

### 2.4 Volumen, crecimiento y retención

Estimaciones sobre la organización de referencia de 1.2, como insumo del punto 14. El objetivo
no es la precisión sino distinguir **qué crece con la organización y qué crece con el uso**.

| Dato | Orden de magnitud | Cómo crece | Retención |
|---|---|---|---|
| `usuario`, `area`, `rol` | Miles / decenas | Con la organización | Permanente, con baja lógica |
| `acl_documento` | Decenas de miles | Con el catálogo | Permanente, con historial de cambios |
| `documento` | Decenas de miles | Con el catálogo | Permanente |
| `documento_version` | ~2 a 3 por documento | Con el catálogo | Permanente por obligación regulatoria |
| `chunk` | Millones | Con el catálogo, multiplicado por la granularidad de fragmentación | Ligada a la versión |
| `consulta` | ~1 millón por año | **Con el uso** | A definir; contiene posibles datos personales (R7) |
| `respuesta` | Una por consulta | **Con el uso** | Igual que `consulta` |
| `respuesta_fuente` | 5 a 8 por respuesta: varios millones por año | **Con el uso** | Necesaria mientras la respuesta sea auditable |
| `log_acceso`, `auditoria` | Decenas de millones acumulados | **Con el uso** | Definida por la política de auditoría, típicamente varios años |

Quedan así dos grupos con exigencias opuestas. El catálogo documental y sus fragmentos son
grandes pero estables, y se optimizan para lectura. Las tablas de eventos —consultas, respuestas,
fuentes, accesos y auditoría— crecen de forma indefinida con el uso, se escriben mucho más de lo
que se leen y casi siempre se consultan acotadas por fecha. Esa diferencia justifica tratarlas
con una estrategia de almacenamiento distinta (punto 14).

### 2.5 Trazabilidad entre requisitos y datos relevados

Verificación de cierre: cada exigencia del caso y cada riesgo de 1.7 tienen datos que los
cubren.

| Requisito o riesgo | Datos relevados que lo cubren |
|---|---|
| Cargar y clasificar documentación técnica | `documento`, `tipo_documento`, `area`, `etiqueta`, metadatos variables |
| Dividirla en fragmentos consultables | `chunk` asociado a `documento_version` |
| Responder preguntas en lenguaje natural | `consulta` y su representación vectorial, `chunk` y la suya |
| Registrar qué documentos se usaron en cada respuesta | `respuesta_fuente` con puntaje y posición |
| No todos los usuarios acceden a todos los documentos | `acl_documento`, `nivel_confidencialidad`, `usuario`, `rol`, `area` |
| R1 Fuga por recuperación | `acl_documento` aplicado sobre `chunk` y `documento` |
| R2 Documentación desactualizada | Estado de `documento`, vigencia de `documento_version`, `documento_relacion` |
| R3 Falta de trazabilidad | `respuesta_fuente`, `log_acceso`, `auditoria` |
| R4 Duplicación por reingesta | Hash SHA-256 en `documento_version` |
| R5 Vectores heterogéneos | `modelo_embedding` |
| R6 Permisos amplios o vencidos | Ventana de vigencia en `acl_documento` y su registro en `auditoria` |
| R7 Datos personales en consultas | Identificación de `consulta` como dato sensible y su política de retención |
| R8 Derivados sin protección | Restricción sobre el contenido de la capa analítica (2.1.F) |

---

## 3. Clasificación de los datos

El punto 2 identificó qué datos hay. Este los clasifica en tres ejes, porque cada uno condiciona
decisiones distintas: la **estructura** determina cómo se almacenan y se consultan, la **función**
determina el régimen de escritura y de retención, y la **sensibilidad** determina quién los ve.

### 3.1 Por estructura

| Categoría | Qué incluye | Cómo se representa |
|---|---|---|
| **Estructurados** | Catálogos, identidades, roles y permisos, otorgamientos, cabecera de documentos y versiones, relaciones entre documentos, citas de fuentes | Columnas tipadas con restricciones declaradas |
| **Semiestructurados** | Metadatos que varían según el tipo de documento, posición del fragmento en su documento, contexto de un acceso, valores anterior y posterior de un cambio auditado | `JSONB` |
| **No estructurados** | Texto extraído de la versión, texto del fragmento, pregunta del usuario, respuesta generada, comentario del feedback | Columnas de texto |
| **Vectoriales** | Representación semántica del fragmento y de la pregunta | `vector(1024)` |

Dos aclaraciones sobre esta división.

La representación para búsqueda de texto completo (`chunk.tsv`) no es un dato nuevo ni es
vectorial en el sentido denso: es un índice invertido de lexemas derivado del mismo texto, y lo
calcula la base como columna generada. Se la nombra acá porque es la contracara del embedding —
una responde por significado y la otra por término exacto— pero no es información adicional.

La frontera entre no estructurado y vectorial es de representación y no de contenido. El mismo
fragmento existe a la vez como texto y como vector, y esa duplicación es deliberada: cada forma
responde un tipo de pregunta que la otra no puede.

### 3.2 Por función

| Clase | Entidades | Régimen | Retención |
|---|---|---|---|
| **De referencia** | `area`, `rol`, `permiso`, `nivel_confidencialidad`, `tipo_documento`, `etiqueta`, `modelo_embedding` | Casi solo lectura | Permanente |
| **Operacionales** | `usuario`, `acl_documento`, `documento`, `documento_version`, `documento_relacion`, `chunk` | Lectura intensiva, escritura controlada | Permanente; las versiones, por obligación regulatoria |
| **De eventos** | `consulta`, `respuesta`, `respuesta_fuente`, `feedback` | Solo inserción, alto volumen | A definir por política (punto 14) |
| **De auditoría** | `log_acceso`, `auditoria` | Solo inserción, no modificables | Definida por la política de auditoría |
| **Derivados** | Vistas materializadas del esquema `analytics` | Recalculables | No tienen retención propia |

La diferencia entre eventos y auditoría no es de volumen: es de garantía. Un registro de eventos
puede borrarse cuando vence la política de retención; uno de auditoría no puede modificarse
mientras exista (RD13). Esa distinción se implementa con permisos de la base, no con disciplina
de la aplicación.

### 3.3 Por sensibilidad

Hay dos escalas superpuestas: la clasificación del dominio, que se aplica a la documentación, y
la condición de dato personal, que se aplica a las personas.

| Dato | Por qué es sensible | Consecuencia |
|---|---|---|
| `documento.nivel_id` | Clasificación declarada en una escala ordenada de cuatro niveles | Es uno de los dos extremos de la regla de acceso de 4.4 |
| `chunk` (texto y vector) | Hereda la clasificación de su documento y es lo que entra al contexto del modelo | Es el dato que puede filtrar información (R1) |
| `acl_documento` | No es sensible en sí, pero una fila mal puesta expone un documento entero | Criticidad máxima; sus cambios se auditan |
| `usuario.nombre`, `correo`, `identidad_ext` | Datos personales de empleados | Baja lógica, nunca borrado físico |
| `consulta.texto` | El usuario puede escribir el documento de un cliente o el nombre de un empleado | R7: una tabla de uso pasa a contener datos personales |
| `feedback.comentario` | Texto libre, mismo problema que la consulta | Igual tratamiento que `consulta` |
| `log_acceso`, `auditoria` | Revelan el comportamiento de personas identificadas | Acceso restringido al perfil de auditoría |

El caso menos evidente es el embedding. No es texto, pero tampoco es un dato técnico neutro: se
deriva del contenido y permite reconstruirlo parcialmente. Se lo trata con el mismo nivel de
confidencialidad que el fragmento del que proviene, y no como un vector anónimo.

Esta clasificación se aplica al propio trabajo: **el conjunto de datos de ejemplo usa identidades
seudonimizadas** —nombres ficticios y direcciones sobre un dominio de ejemplo—, con forma
realista para que las consultas de demostración sean creíbles, pero sin datos personales
verdaderos. El repositorio es público, y un trabajo que argumenta cómo se protegen los datos
personales no puede exhibirlos. La generación se desarrolla en el punto 9.

### 3.4 Síntesis por entidad

| Entidad | Estructura | Función | Sensibilidad |
|---|---|---|---|
| `area`, `rol`, `permiso`, `tipo_documento`, `etiqueta` | Estructurada | De referencia | Baja |
| `nivel_confidencialidad` | Estructurada | De referencia | Alta: define la escala de acceso |
| `usuario` | Estructurada | Operacional | Alta: datos personales |
| `acl_documento` | Estructurada | Operacional | Máxima |
| `documento` | Estructurada + semiestructurada (`metadatos`) | Operacional | Alta: lleva la clasificación |
| `documento_version` | Estructurada + no estructurada (`texto`) | Operacional | Alta: hereda del documento |
| `documento_relacion` | Estructurada | Operacional | Baja |
| `chunk` | Estructurada + no estructurada + vectorial + semiestructurada | Operacional | Máxima |
| `modelo_embedding` | Estructurada | De referencia | Baja |
| `consulta` | Estructurada + no estructurada + vectorial | De eventos | Alta: posibles datos personales |
| `respuesta` | Estructurada + no estructurada | De eventos | Media |
| `respuesta_fuente` | Estructurada | De eventos | Máxima: es la traza de la respuesta |
| `feedback` | Estructurada + no estructurada | De eventos | Media |
| `log_acceso` | Estructurada + semiestructurada (`contexto`) | De auditoría | Alta |
| `auditoria` | Estructurada + semiestructurada (`datos_antes`, `datos_despues`) | De auditoría | Máxima |

### 3.5 Qué se desprende de la clasificación

- Los **semiestructurados** van en `JSONB` con índice `GIN`, y no en una tabla de atributos
  genéricos ni en columnas mayormente vacías (D6). Se desarrolla en los puntos 6 y 11.
- De los **no estructurados**, el binario queda fuera de la base y el texto adentro (D5). El
  texto tiene que estar porque se fragmenta y se busca; el binario no aporta a la recuperación.
- Los **vectoriales** obligan a registrar con qué modelo y con qué dimensión se generaron (R5),
  porque vectores de modelos distintos no son comparables y la degradación es silenciosa.
- Los **datos personales** de `consulta` y `feedback` obligan a fijar una política de retención,
  y es donde el punto 13 se cruza con el 14.
- Los **de auditoría** se protegen con permisos de la base y no con convenciones de la
  aplicación (RD13).
- Los **derivados** no pueden contener texto de fragmentos (R8): la clasificación no viaja con
  una copia, así que la capa analítica guarda identificadores y magnitudes agregadas.

## 4. Modelo conceptual

Los diagramas entidad-relación están en
[`docs/diagramas/modelo_conceptual.md`](diagramas/modelo_conceptual.md): una vista general y tres
vistas por subdominio con los atributos de cada entidad. Este punto justifica lo que ahí se
representa.

### 4.1 Criterio del modelo

El modelo describe **qué información existe y cómo se relaciona**, con el identificador de cada
entidad pero sin tipos de dato, claves foráneas ni estrategias de almacenamiento: eso es el punto
5. Se siguieron tres criterios.

**Las relaciones muchos a muchos con atributos propios se modelan como entidad.** Un usuario
desempeña varios roles y un rol lo desempeñan varios usuarios: esa relación no guarda nada más
que el vínculo, y se representa directamente. En cambio, el otorgamiento de acceso guarda quién
lo concedió y hasta cuándo, y la cita de una fuente guarda el puntaje y la posición en el
ranking: esa información no pertenece a ninguno de los dos extremos, así que `acl_documento`,
`respuesta_fuente` y `documento_relacion` son entidades.

**Todo atributo derivable no se almacena como atributo.** El nivel de confidencialidad de un
fragmento no se guarda en el fragmento: se deduce de su documento. Guardarlo dos veces
introduciría la posibilidad de que difieran, y en este caso esa divergencia sería una fuga.

**Las entidades de eventos no se actualizan.** Consultas, respuestas, fuentes citadas y registros
de auditoría solo se insertan: una respuesta que se puede editar deja de ser evidencia de lo que
el sistema contestó.

### 4.2 Entidades

**Organización y control de acceso**

| Entidad | Qué representa | Se identifica por |
|---|---|---|
| `area` | Unidad organizativa propietaria de documentación | Nombre |
| `usuario` | Persona que consulta o administra documentación | Identificador corporativo |
| `rol` | Función que agrupa permisos sobre el sistema | Nombre |
| `permiso` | Acción habilitada: consultar, cargar, publicar, derogar, otorgar acceso, auditar | Código |
| `nivel_confidencialidad` | Escala ordenada de clasificación de la información | Nombre y orden |
| `acl_documento` | Otorgamiento de acceso a un documento para un sujeto, con su vigencia | Documento + sujeto + vigencia |

**Documentación y contenido**

| Entidad | Qué representa | Se identifica por |
|---|---|---|
| `tipo_documento` | Clase de documento, que determina qué metadatos propios tiene | Nombre |
| `documento` | Unidad documental estable a lo largo de sus versiones | Código documental |
| `documento_version` | Estado publicado del documento en un momento dado | Documento + número de versión |
| `documento_relacion` | Vínculo dirigido entre dos documentos y su tipo | Origen + destino + tipo |
| `etiqueta` | Término de clasificación transversal a las áreas | Nombre |
| `chunk` | Fragmento recuperable de una versión, con su representación vectorial | Versión + orden |
| `modelo_embedding` | Modelo con el que se generó una representación vectorial, y su dimensión | Nombre |

**Uso y auditoría**

| Entidad | Qué representa | Se identifica por |
|---|---|---|
| `consulta` | Pregunta formulada por un usuario, con su representación vectorial | Sustituto |
| `respuesta` | Texto generado para una consulta | Consulta |
| `respuesta_fuente` | Fragmento que alimentó una respuesta, con su puntaje y posición | Respuesta + fragmento |
| `feedback` | Valoración de utilidad de una respuesta | Respuesta + usuario |
| `log_acceso` | Acceso a un documento, concedido o denegado | Sustituto |
| `auditoria` | Cambio sobre datos sensibles, con su valor anterior y posterior | Sustituto |

`documento` y `documento_version` son dos entidades y no una porque cumplen funciones distintas:
el documento es la identidad estable a la que se refieren las relaciones y los otorgamientos de
acceso —que no deberían reasignarse en cada publicación—, y la versión es el contenido concreto,
inmutable, que se fragmenta y se cita. Es la contracara de la decisión D2 del punto 1.

### 4.3 Relaciones y cardinalidades

| Relación | Cardinalidad | Lectura |
|---|---|---|
| `area` – `usuario` | 1 : N | Un área agrupa a varios usuarios y cada usuario pertenece a un área |
| `area` – `documento` | 1 : N | Cada documento tiene un área propietaria |
| `usuario` – `rol` | N : N | Un usuario desempeña varios roles y viceversa |
| `rol` – `permiso` | N : N | Un rol concede varios permisos y un permiso está en varios roles |
| `nivel_confidencialidad` – `documento` | 1 : N | Cada documento tiene exactamente una clasificación |
| `nivel_confidencialidad` – `usuario` | 1 : N | Cada usuario tiene un nivel de habilitación |
| `documento` – `acl_documento` | 1 : N | Un documento puede tener varios otorgamientos |
| `acl_documento` – sujeto (`area`, `rol` o `usuario`) | 1 : N | Cada otorgamiento tiene exactamente un sujeto, de uno de los tres tipos |
| `usuario` – `acl_documento` (otorgante) | 1 : N | Todo otorgamiento registra quién lo concedió |
| `tipo_documento` – `documento` | 1 : N | Cada documento es de un solo tipo |
| `documento` – `documento_version` | 1 : N | Todo documento tiene al menos una versión |
| `documento` – `documento_relacion` | 1 : N (dos veces) | Un documento es origen y/o destino de varias relaciones |
| `documento` – `etiqueta` | N : N | Etiquetado libre en ambos sentidos |
| `documento_version` – `chunk` | 1 : N | Los fragmentos pertenecen a una versión |
| `modelo_embedding` – `chunk` | 1 : N | Cada fragmento se vectorizó con un modelo |
| `usuario` – `consulta` | 1 : N | Toda consulta tiene un autor identificado |
| `consulta` – `respuesta` | 1 : 1 | Una consulta produce a lo sumo una respuesta |
| `respuesta` – `respuesta_fuente` | 1 : N | Toda respuesta se apoya en al menos un fragmento |
| `chunk` – `respuesta_fuente` | 1 : N | Un fragmento puede citarse en muchas respuestas |
| `respuesta` – `feedback` | 1 : N | Una respuesta puede recibir feedback de varios usuarios |
| `usuario` – `log_acceso`, `auditoria` | 1 : N | Todo evento registra quién lo produjo |

El 1 y la N fijan el máximo de cada extremo. Dos mínimos merecen aclaración:

**Una consulta puede quedarse sin respuesta.** No es un error del sistema: es el caso en que la
recuperación no encontró material autorizado y vigente para contestar. Exigir una respuesta por
consulta obligaría a inventar respuestas vacías y borraría la señal más valiosa del sistema, que
es la lista de preguntas sin cobertura.

**Una versión puede no tener ningún fragmento.** Una versión recién ingerida todavía no está
fragmentada. La obligación de tener al menos uno aplica a las versiones publicadas, no a todas, y
por eso se expresa como restricción de dominio (RD9) y no como cardinalidad.

### 4.4 La regla de acceso

Es la restricción más importante del modelo, la que después se implementa dentro del motor
(decisión D1). Un usuario `u` puede acceder a un documento `d` si y solo si se cumplen **las dos**
condiciones:

```
Acceso(u, d)  ⟺   orden(nivel(d)) ≤ orden(habilitacion(u))
                  ∧ ( nivel(d) = público  ∨  ∃ otorgamiento vigente que alcance a u )
```

donde un otorgamiento alcanza a `u` si su sujeto es el área de `u`, alguno de los roles de `u`, o
`u` en persona, y está dentro de su ventana de vigencia.

Esto resuelve la duda que quedó abierta sobre si el nivel de confidencialidad debía ser una
**jerarquía ordenada** o un conjunto de permisos sueltos. Es una jerarquía ordenada —quien está
habilitado a *confidencial* lo está también a *interno* y a *público*—, pero **no alcanza por sí
sola**:

- **Si el acceso dependiera solo del nivel**, cualquier usuario con habilitación alta vería toda
  la documentación de su nivel o inferior. Contradice el relevamiento de usuarios del punto 1.4:
  un administrador de sistemas necesita habilitación alta para los manuales del core, y eso no
  debe darle acceso a los informes de investigación de fraude, que están en el mismo nivel.
- **Si el acceso dependiera solo de los otorgamientos**, un otorgamiento mal emitido —el riesgo
  R6, el más frecuente de todos— alcanzaría para exponer un documento restringido a quien no
  tiene habilitación para ese nivel.

Al exigir las dos condiciones, el nivel funciona como un techo que ningún otorgamiento puede
levantar, y el otorgamiento como una llave que ninguna habilitación reemplaza. Un error humano en
la clasificación o en la asignación de permisos deja de ser suficiente, por sí solo, para
producir una fuga.

La excepción de los documentos públicos evita el absurdo de tener que emitir un otorgamiento por
cada área para documentación que, por definición, puede leer cualquiera.

### 4.5 Restricciones del dominio

Restricciones que el modelo debe garantizar y que **no se derivan de las cardinalidades**. Cómo
se verifica cada una es materia de los puntos 5 y 8.

| # | Restricción | Cómo se verifica |
|---|---|---|
| RD1 | Un fragmento no tiene clasificación ni vigencia propias: las hereda de su versión y de su documento | Derivación, nunca atributo duplicado |
| RD2 | Las ventanas de vigencia de las versiones de un mismo documento no se solapan: hay a lo sumo una versión vigente en cada instante | Restricción de exclusión sobre el rango de fechas |
| RD3 | `vigente_hasta` es nulo (vigencia abierta) o posterior a `vigente_desde` | Restricción de verificación |
| RD4 | Un documento en estado *derogado* no puede tener ninguna versión con vigencia abierta | Disparador |
| RD5 | Las relaciones *deroga* y *reemplaza* no admiten ciclos: ningún documento se deroga a sí mismo, ni directa ni transitivamente | Verificación en el recorrido recursivo |
| RD6 | El hash del archivo original es único en todo el sistema | Restricción de unicidad |
| RD7 | Todo otorgamiento tiene exactamente un sujeto: área, rol o usuario, nunca dos ni ninguno | Arco exclusivo, ver 4.6 |
| RD8 | Quien otorga un acceso debe tener el permiso de otorgar acceso | Regla de aplicación, auditada |
| RD9 | Toda versión publicada tiene al menos un fragmento, y sus órdenes son únicos y consecutivos | Unicidad + validación de la ingesta |
| RD10 | Las posiciones de las fuentes de una respuesta son únicas y consecutivas desde 1 | Restricción de unicidad |
| RD11 | Todo fragmento citado en una respuesta era accesible para el autor de la consulta en el momento de consultarla | Se garantiza por construcción: la recuperación ya filtró |
| RD12 | Todos los fragmentos comparables entre sí comparten modelo de vectorización y dimensión | Referencia a `modelo_embedding` |
| RD13 | Las entidades de auditoría no admiten modificación ni borrado | Permisos de la base, no de la aplicación |
| RD14 | La escala de niveles de confidencialidad es total y su orden no se reasigna | Unicidad sobre el orden |
| RD15 | Un usuario deja a lo sumo un feedback por respuesta | Restricción de unicidad |

RD11 es la que cierra el modelo de seguridad. Todas las demás se pueden verificar mirando la
base; esta se sostiene en que la única vía por la que un fragmento llega a `respuesta_fuente` es
la recuperación, y la recuperación ya está filtrada por la regla de 4.4. Si existiera otro camino
para insertar fuentes, la garantía se rompe: es la razón por la que el filtro tiene que vivir en
el motor y no en el código que consulta.

### 4.6 Qué queda pendiente para el modelo lógico

Tres cuestiones se identifican acá pero se resuelven en el punto 5, porque dependen de decisiones
de implementación:

**El sujeto del otorgamiento.** `acl_documento` apunta a un área, a un rol o a un usuario, nunca a
más de uno. Conceptualmente es un arco exclusivo; en el modelo lógico hay que optar entre tres
referencias opcionales con una verificación que garantice que exactamente una está presente, o
tres entidades separadas. La primera opción mantiene una sola tabla que las políticas de acceso
consultan; la segunda es más estricta pero triplica esa consulta.

**Los metadatos variables por tipo de documento.** El modelo conceptual dice que `documento` tiene
metadatos que dependen de su tipo. Cómo se representan —y por qué no como una tabla de atributos
genéricos— es la decisión D6, que se desarrolla en los puntos 5, 6 y 11.

**La representación de la escala de niveles.** Que la jerarquía sea ordenada permite representarla
como una entidad con un atributo de orden o como un tipo enumerado. Se define en el punto 5 junto
con el resto de los catálogos.

## 5. Modelo de implementación

El punto 4 describió qué información existe y cómo se relaciona. Este define cómo se representa
en un motor relacional: tablas, claves, restricciones y la traducción de cada cardinalidad. Lo
implementa [`db/estructura/03_tablas.sql`](../db/estructura/03_tablas.sql), que crea 22 tablas y
dos tipos enumerados sobre el esquema `core`.

### 5.1 Criterios de traducción

**Clave sustituta en todas las entidades, clave natural declarada como única.** Las claves
naturales del dominio —el código documental, el identificador corporativo, el nombre del área—
son estables pero no inmutables, y varias se referencian desde tablas de alto volumen. Una clave
sustituta angosta mantiene chicos los índices y las claves foráneas. La clave natural no se
pierde: queda como restricción de unicidad, que es donde cumple su función.

La excepción es `nivel_confidencialidad`, cuyo identificador se asigna a mano. Es un catálogo
cerrado de cuatro filas cuyo orden participa de la regla de acceso, y conviene que sus
identificadores sean estables y legibles en las políticas.

**Los catálogos son tablas, no tipos enumerados.** Un enumerado no admite atributos, y los
catálogos de este modelo los necesitan: el nivel lleva `orden`, el tipo de documento lleva
descripción. Además, agregar un valor a un enumerado exige `ALTER TYPE`. Se usan enumerados solo
donde el conjunto es cerrado y sin atributos propios: `estado_documento` y
`tipo_relacion_documento`.

**Toda tabla lleva `COMMENT ON`**, con lo que representa y con la decisión o el riesgo del punto
1 al que responde.

### 5.2 Traducción de las relaciones

| Cardinalidad conceptual | Cómo se implementa | Ejemplo |
|---|---|---|
| 1 : N obligatoria | Clave foránea `NOT NULL` en el lado N | `documento.area_id` |
| 1 : N opcional | Clave foránea que admite nulo | `log_acceso.documento_id` |
| N : M sin atributos | Tabla puente con clave primaria compuesta | `usuario_rol`, `rol_permiso`, `documento_etiqueta` |
| N : M con atributos | Entidad propia con sus columnas | `acl_documento`, `respuesta_fuente`, `documento_relacion` |
| 1 : 1 (a lo sumo una) | Clave foránea más restricción de unicidad en el lado dependiente | `respuesta.consulta_id` |
| Arco exclusivo | Tres claves foráneas opcionales más verificación de que hay exactamente una | `acl_documento` |
| Autorrelación | Dos claves foráneas a la misma tabla más verificación anti-reflexiva | `documento_relacion` |

### 5.3 Claves

| Grupo | Clave primaria | Por qué |
|---|---|---|
| Entidades | Sustituta generada por identidad | Estabilidad y tamaño |
| Tablas puente | Compuesta por las dos foráneas | La combinación es el hecho que se registra |
| `documento_relacion` | Origen + destino + tipo | Dos documentos pueden vincularse por más de un motivo |
| Tablas particionadas | Sustituta + `creado_en` | En una tabla particionada la clave primaria debe incluir la clave de partición |

Las claves foráneas entre tablas particionadas arrastran la fecha (`respuesta` referencia a
`consulta` por `(id, creado_en)`). Además de satisfacer la restricción anterior, eso garantiza
que padre e hijo caigan en la misma partición.

### 5.4 Las tres cuestiones que quedaron abiertas en 4.6

**El sujeto del otorgamiento.** Se resuelve con tres referencias opcionales y la verificación
`num_nonnulls(area_id, rol_id, usuario_id) = 1`, en lugar de tres tablas separadas. El criterio
fue el costo de la consulta que más se ejecuta: las políticas de seguridad por fila consultan
esta tabla en cada recuperación, y una sola tabla mantiene la política legible y el plan de
ejecución simple. Tres tablas serían más estrictas pero triplicarían esa consulta.

**Los metadatos variables.** Se resuelven con `jsonb NOT NULL DEFAULT '{}'` y la verificación de
que el valor sea un objeto. El desarrollo de por qué no una tabla de atributos genéricos es el
punto 6.

**La escala de niveles.** Se representa como tabla catálogo con un atributo `orden` único, no
como enumerado, porque el orden se compara dentro de la regla de acceso y porque incorporar un
nivel intermedio no debería exigir modificar un tipo.

### 5.5 Lo que falta cerrar

Tres definiciones que este punto fija y que todavía no están en el DDL.

**El nivel de habilitación del usuario.** El modelo conceptual tiene la relación
`nivel_confidencialidad 1 — habilita hasta — N usuario` y la regla de acceso de 4.4 la necesita,
pero `usuario` no la implementa. Se agrega como `nivel_habilitacion_id smallint NOT NULL
REFERENCES nivel_confidencialidad(id)`. Se descartó derivarla del rol: la habilitación es una
propiedad de la persona y no de la función que cumple, y dos usuarios con el mismo rol pueden
tenerla distinta. Sin esta columna, la primera condición de la regla de acceso no tiene dónde
apoyarse y las políticas quedarían con una sola de las dos.

**Unicidad de la respuesta por consulta.** La cardinalidad 1 : 1 de 4.3 exige
`UNIQUE (consulta_id, creado_en)` sobre `respuesta`, que hoy no está declarada.

**Unicidad de la posición dentro de una respuesta.** RD10 exige
`UNIQUE (respuesta_id, posicion, creado_en)` sobre `respuesta_fuente`.

### 5.6 Estado de las restricciones del dominio

Cómo queda implementada cada restricción del punto 4.5.

| # | Cómo se implementa | Estado |
|---|---|---|
| RD1 | Derivación en consultas y políticas; el fragmento no guarda clasificación propia | Por construcción |
| RD2 | Restricción de exclusión sobre el rango de vigencia | Declarada, con `btree_gist` |
| RD3 | Verificación sobre las fechas de la versión | Declarada |
| RD4 | Disparador sobre el estado del documento | Pendiente |
| RD5 | Verificación en el recorrido recursivo | Pendiente |
| RD6 | Unicidad sobre `hash_sha256` | Declarada |
| RD7 | Verificación de exactamente un sujeto | Declarada |
| RD8 | Regla de aplicación, auditada | Declarada (`05_rls.sql`): `acl_documento` no es alcanzable desde `tp_lector` |
| RD9 | Unicidad de `(version, orden)` más validación en la ingesta | Parcial: falta lo consecutivo |
| RD10 | Unicidad de `(respuesta, posicion)` | Declarada |
| RD11 | Por construcción: la única vía a `respuesta_fuente` es la recuperación, ya filtrada | Cumplida (`05_rls.sql` filtra `chunk` antes) |
| RD12 | Referencia a `modelo_embedding` y dimensión fijada en el tipo de la columna | Declarada |
| RD13 | Permisos y políticas de la base | Declarada (`05_rls.sql`): ningún rol tiene `UPDATE` ni `DELETE` sobre `log_acceso` ni `auditoria` |
| RD14 | Unicidad sobre `orden` | Declarada |
| RD15 | Unicidad de `(respuesta, usuario)` | Declarada |

Las que siguen pendientes (RD4, RD5, y la mitad consecutiva de RD9) dependen de disparadores
que no se llegaron a escribir; se retoman en el punto 8.2. El resto se cerró en
`03_tablas.sql`, `04_particiones.sql` y `05_rls.sql`.

## 6. Normalización, desnormalización y embebido

El modelo relacional del punto 5 está en tercera forma normal, con tres desviaciones deliberadas.
Este punto justifica hasta dónde se normalizó, qué anomalías evita esa decisión, y con qué
criterio se resolvió cada vez que un dato podía ir embebido en una fila o referenciado desde otra
tabla.

### 6.1 Hasta qué forma normal

**Primera forma normal.** Todos los atributos son atómicos, con una excepción aparente: las
columnas `JSONB`. Un documento estructurado dentro de una fila parece una violación, porque sus
campos internos son varios valores en una sola columna. No lo es en este modelo, y la razón es
precisa: esos campos **no forman parte del universo del discurso**. Varían de un tipo de documento
a otro, ninguna restricción del dominio depende de ellos, y ninguna relación los referencia. Para
el esquema relacional, `metadatos` es un valor atómico; su estructura interna la interpreta quien
consulta, no el modelo.

**Segunda forma normal.** Ningún atributo depende de parte de una clave compuesta. Las claves
compuestas del modelo son de dos clases: las de las tablas puente, que no tienen atributos fuera
de la marca temporal del vínculo, y las de las tablas particionadas, que se tratan en 6.4.

**Tercera forma normal.** No hay dependencias transitivas entre atributos que no son clave. El
caso que las evita explícitamente es el nivel de confidencialidad: no se guarda en el fragmento
ni en la versión, sino solo en el documento, y desde ahí se deriva.

En la práctica el modelo cumple también Boyce-Codd, porque en toda tabla el único determinante es
una clave candidata. Donde hay dos claves candidatas —`nivel_confidencialidad` tiene `nombre` y
`orden`, ambos únicos— ninguna determina a la otra fuera de la fila que las contiene.

### 6.2 Qué anomalías evita

| Anomalía | Cómo aparecería acá | Qué la evita |
|---|---|---|
| **Actualización** | Si el fragmento guardara copia del nivel de confidencialidad de su documento, reclasificar un documento obligaría a actualizar millones de fragmentos | RD1: el fragmento hereda, no copia |
| **Inserción** | Si el otorgamiento fuera un atributo de `documento` —una lista de áreas habilitadas— no habría dónde registrar quién lo concedió ni hasta cuándo | `acl_documento` como entidad |
| **Borrado** | Si el nombre y la dimensión del modelo de vectorización fueran columnas de `chunk`, dar de baja el último fragmento de un modelo borraría el registro de que ese modelo existió | `modelo_embedding` como entidad |

La primera merece subrayarse porque su consecuencia no es la habitual. En un modelo cualquiera,
una anomalía de actualización produce datos inconsistentes. Acá produce una **fuga**: un fragmento
que quedó con la clasificación vieja después de que su documento se reclasificara hacia arriba es
un fragmento que la recuperación va a entregar a quien no corresponde. Es el argumento que hace
que la normalización de este modelo no sea una cuestión de prolijidad.

### 6.3 Embebido contra referencias

El criterio es uno solo: **se embebe lo que no tiene identidad propia, no se comparte, y no
participa de ninguna restricción de integridad. Se referencia todo lo demás.**

| Dato | Decisión | Por qué |
|---|---|---|
| `documento.metadatos` | Embebido | Varía según el tipo, no se comparte entre documentos, y ninguna restricción depende de sus campos |
| `chunk.metadatos` | Embebido | Describe la posición del fragmento en su documento; nace y muere con él |
| `auditoria.datos_antes`, `datos_despues` | Embebido | La forma cambia según la entidad auditada: no existe un esquema fijo posible |
| `log_acceso.contexto` | Embebido | Igual que el anterior, y solo se lee al investigar un caso puntual |
| `chunk.embedding` | Embebido en la fila | Hay exactamente un vector por fragmento y siempre se recupera junto con su texto; una tabla aparte agregaría una unión en la consulta más caliente del sistema sin ganar nada |
| `tipo_documento`, `nivel_confidencialidad` | Referencia | Tienen identidad, se comparten, y participan de restricciones: el `orden` del nivel se compara dentro de la regla de acceso |
| `etiqueta` | Referencia (N:M) | El vocabulario tiene que ser común. Embebida como arreglo en `documento` convivirían «kyc», «KYC» y «Kyc» como etiquetas distintas |
| `acl_documento` | Referencia | Tiene atributos propios —vigencia, otorgante, motivo— y es la tabla que consultan las políticas de acceso |

Hay una sola excepción al criterio, y es deliberada. `auditoria` identifica lo que audita con un
nombre de entidad y un identificador, **sin clave foránea**. Es una referencia lógica sin
integridad referencial, y se acepta porque el registro tiene que sobrevivir a la baja de aquello
que audita: con una clave foránea, borrar un otorgamiento borraría también la constancia de que
existió.

### 6.4 Las desnormalizaciones adoptadas

| Qué | Por qué | Qué se paga |
|---|---|---|
| Metadatos variables en `JSONB` | La alternativa normalizada es una tabla de atributos genéricos, que pierde la verificación de tipos, degrada los planes de ejecución y obliga a reconstruir cada documento con tantas uniones como atributos tenga | No hay verificación declarada campo por campo |
| La clave de partición dentro de la clave primaria | El particionado declarativo lo exige. En `respuesta_fuente`, `creado_en` está funcionalmente determinado por `respuesta_id`, así que como parte de la clave es redundante | Una columna repetida por fila en las tablas de mayor volumen |
| `feedback.respuesta_creado_en` | Copia explícita de la marca temporal de la respuesta, única forma de referenciar una tabla particionada | Igual que el anterior |
| `chunk.tsv` | Representación derivada del texto, es decir redundancia pura. Calcularla en cada consulta sería inviable | Espacio, y nada más: es una columna generada y la mantiene la base |
| Vistas materializadas de `analytics` | Agregaciones precalculadas sobre datos que ya existen | Desfase entre el refresco y el dato vivo, aceptable para indicadores |

Las dos primeras y la tercera tienen la misma justificación de fondo: **la redundancia la impone o
la mantiene el motor, no la aplicación.** Una clave de partición la exige PostgreSQL; una columna
generada la recalcula PostgreSQL; una vista materializada se refresca con un comando. En ninguna
de las tres hay código de aplicación que pueda olvidarse de sincronizar algo.

### 6.5 La desnormalización que no se hace

La más tentadora del modelo sería copiar `nivel_id` y el estado del documento a `chunk`. Ahorraría
dos uniones en la consulta que más se ejecuta —la recuperación— y en una base de millones de
fragmentos eso se nota.

No se hace, y el motivo es el mismo de 6.2: una divergencia entre la clasificación del documento y
la copia guardada en el fragmento no es una inconsistencia que se corrige después, es un fragmento
prohibido que la recuperación entrega. Si el rendimiento llegara a exigirlo, se resuelve con un
índice adecuado o con una vista, no duplicando el dato que decide quién ve qué.

Por la misma razón se descarta copiar el título del documento a `respuesta_fuente` para mostrar la
cita sin uniones.

### 6.6 Síntesis

Tercera forma normal como norma, y tres excepciones que comparten una forma: se acepta redundancia
cuando el motor la impone o la mantiene solo. No se acepta ninguna redundancia que dependa de que
la aplicación la mantenga sincronizada, porque en este modelo una divergencia entre dos copias del
mismo dato de clasificación no produce un informe mal sumado: produce una filtración.

## 7. Selección y justificación de la tecnología

La solución se implementa sobre **PostgreSQL 17 con pgvector, como motor único**. Este punto
justifica esa elección contra las exigencias que impone el caso, y desarrolla las alternativas que
se evaluaron y se descartaron.

### 7.1 Qué exige el caso

Los criterios no salen de una lista genérica: salen del relevamiento del punto 2 y de la
clasificación del punto 3.

| Criterio | Qué exige en este caso |
|---|---|
| **Variabilidad de los datos** | Cuatro clases conviviendo sobre las mismas entidades: estructurados, semiestructurados, no estructurados y vectoriales (punto 3.1) |
| **Patrones de consulta** | Recuperación híbrida —semántica y por término exacto— en el camino crítico, más recorridos recursivos y agregaciones analíticas fuera de él (punto 2.2) |
| **Control de acceso** | Es el requisito dominante. Tiene que ser inevadible, no una convención que la aplicación respeta (D1, R1) |
| **Volumen y crecimiento** | Dos regímenes opuestos: un catálogo estable de millones de fragmentos y unas tablas de eventos que crecen indefinidamente con el uso (punto 2.4) |
| **Consistencia** | Un otorgamiento de acceso y la traza de una respuesta no pueden ser eventualmente consistentes |
| **Trazabilidad** | Estructuras de solo inserción, no modificables ni siquiera por quien las escribe |

### 7.2 Qué mecanismo resuelve cada exigencia

| Exigencia | Mecanismo | Por qué ese |
|---|---|---|
| Entidades y relaciones con integridad | Modelo relacional normalizado | Claves foráneas y restricciones declaradas: la integridad la garantiza el motor |
| Metadatos variables por tipo | `JSONB` con índice `GIN` | Evita la tabla de atributos genéricos sin renunciar a transacciones ni a integridad (D6, punto 6.3) |
| Búsqueda semántica | `pgvector` con índice HNSW y distancia coseno | Búsqueda aproximada de vecinos más cercanos sin recorrer todos los vectores |
| Términos exactos | `tsvector` en español con `unaccent` | Un número de comunicación o una sigla no se distinguen por similitud semántica |
| Fusión de ambas búsquedas | *Reciprocal Rank Fusion* en SQL | Combina dos rankings sin tener que normalizar puntajes de escalas distintas |
| Tolerancia a errores de tipeo | `pg_trgm` sobre títulos | Búsqueda por título en la interfaz del curador |
| Control de acceso | *Row-Level Security* | El filtro lo aplica el motor, no la consulta |
| Trazabilidad | Tablas de solo inserción con permisos que impiden `UPDATE` y `DELETE` | La garantía es del motor, no de la disciplina de la aplicación |
| Volumen de eventos | Particionado declarativo por rango de fecha | Poda por fecha y mantenimiento por partición |
| Cadenas de derogación | `WITH RECURSIVE` | El grafo entre documentos es real pero chico y poco profundo |

### 7.3 Por qué un solo motor y no un stack

El caso combina tres exigencias que habitualmente empujan a repartir el trabajo entre varias
tecnologías: datos relacionales, metadatos variables y búsqueda vectorial. La decisión de
resolverlo con un motor único no es de comodidad, y descansa en tres argumentos.

**El control de acceso solo se puede garantizar si vive en un único lugar.** Si los vectores
estuvieran en un motor dedicado y los permisos en PostgreSQL, el filtro tendría que aplicarlo la
aplicación: habría que replicar la lógica de acceso en código, mantenerla sincronizada entre dos
sistemas, y confiar en que ninguna consulta se la olvide. Cualquier omisión es una fuga (R1). Con
las políticas dentro del motor, el recuperador puede ser ciego al permiso porque el motor no lo
es.

**El volumen del caso entra holgado.** Con el orden de magnitud estimado en 2.4 —decenas de miles
de documentos y algunos millones de fragmentos— pgvector con índice HNSW resuelve la recuperación
sin necesitar un motor especializado. La complejidad de un segundo almacén se pagaría sin
contrapartida.

**Un stack agrega un modo de falla que el caso no tolera.** Dos motores son dos esquemas de
permisos, dos respaldos, dos ventanas de mantenimiento, y un estado nuevo: el de
desincronización entre ambos. En un caso cuyo requisito dominante es la seguridad, incorporar un
modo de falla distribuido es exactamente el intercambio que no conviene hacer.

### 7.4 Alternativas evaluadas y descartadas

| Alternativa | Qué resolvería | Por qué no | Cuándo sí |
|---|---|---|---|
| **Motor vectorial dedicado** (Qdrant, Milvus, Pinecone) | Búsqueda por similitud a gran escala, con filtrado por metadatos | Sacar los vectores de PostgreSQL rompe el modelo de seguridad: el filtro de permisos pasaría a la aplicación | Arriba de decenas de millones de vectores con alta concurrencia, o si hiciera falta escalar la búsqueda independientemente del resto |
| **Motor de búsqueda** (Elasticsearch, OpenSearch) | Búsqueda híbrida —léxica y vectorial— en un solo producto, que es su terreno natural | El catálogo necesita integridad referencial y transacciones para el versionado y los otorgamientos, y el control de acceso volvería a quedar del lado de la aplicación | Si el trabajo fuera principalmente de búsqueda sobre un corpus sin relaciones fuertes ni permisos por fila |
| **Base documental** (MongoDB) | La variabilidad de metadatos entre tipos de documento | `JSONB` cubre esa variabilidad sin renunciar a integridad referencial, transacciones ni seguridad por fila | Si los documentos no tuvieran relaciones fuertes entre sí y el esquema variara de forma impredecible |
| **Base de grafos** (Neo4j) | El recorrido de las relaciones entre documentos | El grafo es real —deroga, reemplaza, complementa, referencia— pero chico y de poca profundidad: `WITH RECURSIVE` alcanza | Si recorrer relaciones fuera el caso de uso central y no una consulta más entre otras |
| **Clave-valor** (Redis) | Caché de resultados de recuperación | En este alcance no hay una necesidad de caché o de sesión que justifique otro componente | Al escalar, para cachear la recuperación de las preguntas más frecuentes |
| **Archivos originales en la base** | Conservar el binario junto a sus metadatos | Ocupan mucho y no se consultan por su contenido binario (D5) | Nunca en este caso: van a almacenamiento de objetos, y en la base quedan URI, hash y texto extraído |

El patrón que atraviesa la tabla es el mismo en casi todas las filas: cada alternativa resuelve
bien **una** de las exigencias de 7.1, y ninguna resuelve la del control de acceso sin devolverle
el filtro a la aplicación.

### 7.5 Los tres mecanismos que sostienen el diseño

**Seguridad a nivel de fila.** PostgreSQL permite declarar políticas que se aplican
automáticamente a toda consulta sobre una tabla. La aplicación abre la conexión declarando quién
consulta, y a partir de ahí una lectura sobre `chunk` devuelve únicamente los fragmentos que ese
usuario puede ver. El filtro no se puede omitir porque no lo escribe quien consulta. Para este
caso es determinante: es lo que permite que la búsqueda por similitud siga siendo ciega al permiso
sin que eso constituya un riesgo.

**Búsqueda híbrida con fusión de rankings.** La búsqueda vectorial entiende el significado pero
falla con los términos exactos: preguntando por una comunicación identificada por su número, el
vector no la distingue de otras comunicaciones parecidas. La búsqueda de texto completo hace
exactamente lo contrario. *Reciprocal Rank Fusion* combina los dos rankings sumando el inverso de
la posición de cada documento en cada uno, lo que evita tener que normalizar puntajes que están en
escalas incomparables. Se escribe en SQL, sin componentes adicionales.

**Documentos estructurados dentro de la fila.** `JSONB` con índice `GIN` resuelve los metadatos
que varían entre tipos de documento manteniendo el resto del modelo relacional intacto. Es la
pieza que evita tener que sumar una base documental al stack, y su justificación como decisión de
modelado está en el punto 6.3.

### 7.6 Límites de la elección

Una justificación honesta incluye dónde deja de valer. Esta elección se revisaría en tres
escenarios:

- **Crecimiento del corpus por encima de decenas de millones de fragmentos**, con alta
  concurrencia de búsqueda. El índice HNSW empezaría a competir por memoria con la carga
  transaccional, y ahí sí se justificaría separar la recuperación en un motor dedicado, asumiendo
  el costo de replicar el filtro de permisos.
- **Aislamiento entre organizaciones distintas.** La seguridad por fila resuelve el aislamiento
  entre usuarios de una misma organización. Si la solución pasara a servir a varias entidades,
  convendría evaluar esquemas o bases separadas.
- **Corpus multiidioma.** La configuración de búsqueda de texto completo está construida sobre el
  lematizador en español: documentación en otros idiomas exigiría configuraciones adicionales y
  decidir el idioma por documento.

## 8. Implementación mínima

La cátedra definió la implementación mínima en términos literales: crear las estructuras
principales, definir claves, restricciones e índices relevantes, cargar algunos datos de
ejemplo y ejecutar las consultas representativas. Este punto cubre las primeras tres partes de
esa definición —estructuras, restricciones, índices— con lo que efectivamente existe en el
repositorio y con la prueba funcional que se corrió para validarlo. La carga de datos y las
consultas representativas se desarrollan en los puntos 9 y 10.

### 8.1 Qué se construyó

Cinco scripts en `db/estructura/`, numerados porque el orden de ejecución es parte del diseño
—una tabla particionada sin sus particiones no acepta un `INSERT`, y una política de RLS no
puede referenciar una columna que todavía no existe— y dos en `db/indices_vistas/`:

| # | Script | Qué implementa |
|---|---|---|
| 1 | `01_extensiones.sql` | `vector`, `pg_trgm`, `unaccent`, `pgcrypto`, `btree_gist`, y la configuración de búsqueda de texto completo en español (`espanol_unaccent`) |
| 2 | `02_esquemas_roles.sql` | Los esquemas `raw`/`core`/`analytics` (punto 12) y los cuatro roles de conexión (`tp_lector`, `tp_curador`, `tp_auditor`, `tp_admin`) |
| 3 | `03_tablas.sql` | Las 22 tablas del modelo lógico (punto 5), con sus claves, restricciones de verificación y de unicidad, y `COMMENT ON` |
| 4 | `04_particiones.sql` | Las particiones mensuales de 2026 más una partición `DEFAULT` para las cinco tablas de eventos, generadas con un `DO` block en vez de repetir el mismo `CREATE TABLE` sesenta veces |
| 5 | `05_rls.sql` | Las políticas de seguridad por fila sobre `documento`, `documento_version` y `chunk`, y los `GRANT` por tabla y por rol que completan lo que `02_esquemas_roles.sql` había dejado pendiente |
| 6 | `indices_vistas/01_indices.sql` | Los índices justificados contra el relevamiento del punto 2.2 |
| 7 | `indices_vistas/02_vistas_materializadas.sql` | `analytics.consultas_sin_cobertura` |

El rango de particiones (doce meses, 2026) es deliberadamente chico: alcanza para cargar los
datos de ejemplo y para mostrar poda de particiones en un `EXPLAIN`, que es lo que exige la
implementación mínima. No se generan particiones para años futuros ni se automatiza su
creación: eso es una pieza de arquitectura que se analiza en el punto 14, no que se construye
acá, siguiendo la aclaración de la cátedra sobre particionado y escalabilidad.

### 8.2 Estado final de las restricciones del dominio

El punto 5.6 dejó un inventario de las quince restricciones de dominio (RD1 a RD15) del punto
4.5, con su estado al momento de escribirlo. Después de `03_tablas.sql`, `04_particiones.sql`
y `05_rls.sql`, ese estado cambió en cinco filas:

| # | Restricción | Estado al cierre |
|---|---|---|
| RD2 | A lo sumo una versión vigente por documento | **Declarada**: `EXCLUDE USING gist` con `btree_gist`, sobre `(documento_id, daterange(vigente_desde, vigente_hasta, '[]'))` |
| RD8 | Quien otorga un acceso debe tener el permiso de otorgar acceso | **Declarada** por la vía de acceso: `acl_documento` no es alcanzable desde `tp_lector`, y solo `tp_curador`/`tp_admin` pueden escribirla (`05_rls.sql`) |
| RD10 | Posiciones de las fuentes únicas por respuesta | **Declarada**: `UNIQUE (respuesta_id, posicion, creado_en)` |
| RD11 | Todo fragmento citado era accesible para el autor de la consulta | **Cumplida por construcción**: la política de RLS sobre `chunk` es la única vía por la que un fragmento puede llegar a formar parte de un resultado de recuperación |
| RD13 | Las entidades de auditoría no admiten modificación ni borrado | **Declarada**: ningún rol, `tp_admin` incluido, tiene `UPDATE` ni `DELETE` sobre `log_acceso` ni `auditoria` |

Las que siguen pendientes son las que dependen de disparadores todavía no escritos: RD4 (que un
documento derogado no pueda tener una versión con vigencia abierta), RD5 (ausencia de ciclos en
`documento_relacion`) y la mitad de RD9 (que los órdenes de los fragmentos de una versión sean
consecutivos, no solo únicos). Ninguna de las tres es necesaria para cargar el corpus de
ejemplo de forma correcta si quien lo genera respeta esas reglas por construcción, que es lo
que hace el generador del punto 9; quedan documentadas como trabajo futuro y no como una
garantía del motor.

### 8.3 Prueba funcional

La implementación mínima pide una prueba funcional, no solo scripts que compilen. Antes de
integrar cada pieza se corrió contra una instancia real de PostgreSQL 17 con pgvector
(`docker compose`, base reiniciada entre pruebas):

1. Los siete scripts de la tabla anterior corren en secuencia, sobre una base vacía, sin
   ningún error.
2. **RD2** rechaza dos versiones de un mismo documento con vigencia solapada (`ERROR:
   conflicting key value violates exclusion constraint`).
3. **Particionado**: una fila con `creado_en` dentro de 2026 cae en su partición mensual; una
   fila fuera de rango cae en la partición `DEFAULT` sin rechazar el `INSERT`.
4. **RLS**: con un documento de nivel confidencial y un otorgamiento a un solo usuario, ese
   usuario ve el documento y su fragmento; un segundo usuario con la misma habilitación pero
   sin otorgamiento no ve ninguno de los dos. `tp_lector` no puede hacer `SELECT` directo sobre
   `acl_documento` (`ERROR: permission denied`). `tp_curador` y `tp_auditor`, sin ningún
   `usuario_id` de sesión declarado, ven el documento completo.
5. **RD13**: `tp_admin` puede insertar en `auditoria`, pero no puede actualizarla
   (`ERROR: permission denied for table auditoria`).
6. **Índices**: con `enable_seqscan = off`, el planificador resuelve un `ORDER BY embedding
   <=> :vector LIMIT n` con `idx_chunk_embedding_hnsw` y un filtro `tsv @@ plainto_tsquery(...)`
   con `idx_chunk_tsv_gin`.
7. **Vista materializada**: una consulta sin `respuesta_fuente` asociada aparece en
   `analytics.consultas_sin_cobertura` después de un `REFRESH`.

Los siete puntos verifican exactamente las garantías que los puntos 1, 4, 5 y 13 de este
informe afirman que el modelo sostiene, y no solo que el DDL no tiene errores de sintaxis.

### 8.4 Qué queda deliberadamente fuera

| Pieza | Por qué no está acá |
|---|---|
| Datos de ejemplo reales y su carga | Puntos 9 y 10 |
| Disparadores de RD4, RD5 y la parte consecutiva de RD9 | No bloquean la carga del corpus de ejemplo si el generador respeta esas reglas; quedan como trabajo futuro |
| Las tres vistas materializadas restantes (documentos más citados, uso por área, antigüedad de lo consultado) | Se describen y se justifican en el punto 2.1.F; son agregaciones del mismo tipo que la que sí se construyó y no aportan nada nuevo a la validación del diseño |
| Automatización de particiones futuras (`pg_partman` o job programado) | Es arquitectura que se analiza en el punto 14, no implementación mínima (aclaración de la cátedra) |
| Réplica de solo lectura | Fuera del alcance según 1.3 y 12.5 |

## 9. Datos de ejemplo

*(Pendiente — Hernando.)*

## 10. Consultas representativas

*(Pendiente — Hernando.)*

## 11. Datos semiestructurados, no estructurados y vectoriales

*(Pendiente — Hernando.)*

## 12. Arquitectura de datos

El diagrama de la circulación de los datos está en
[`docs/diagramas/arquitectura.md`](diagramas/arquitectura.md). Este punto justifica las capas, los
límites entre componentes y dónde se aplica cada garantía.

### 12.1 Las tres capas

La arquitectura se resuelve con tres esquemas dentro de un mismo motor, y no con tres bases
separadas.

| Capa | Qué contiene | Quién escribe | Quién lee |
|---|---|---|---|
| `raw` | Documentos tal como se reciben, antes de clasificar y fragmentar | El proceso de ingesta | El curador |
| `core` | Catálogo documental, versiones, fragmentos, permisos y registro de uso | La ingesta y la aplicación | La aplicación, con las políticas de acceso aplicadas |
| `analytics` | Agregaciones precalculadas sobre el uso del sistema | El refresco de las vistas | Perfiles de análisis y auditoría |

La separación no es organizativa: es un límite de permisos y de ciclo de vida. `raw` recibe
material sin clasificar, y por lo tanto sin control de acceso aplicable todavía, así que no lo
alcanza nadie fuera del curador. `analytics` es lo contrario: lo lee más gente, y justamente por
eso no puede contener texto de fragmentos (R8).

**Por qué tres esquemas y no tres bases.** Una consulta analítica necesita unir contra el catálogo
—qué área, qué tipo, qué antigüedad tiene lo que se cita— y eso tiene que resolverse sin salir del
motor. Separar en bases distintas reintroduciría el problema de consistencia entre almacenes que
el punto 7.3 descarta, y duplicaría la administración de permisos, que es donde se cometen los
errores que producen fugas.

La implementación mínima no puebla `raw`: el corpus de ejemplo llega ya curado, así que la
preparación escribe directamente sobre `core`. La capa se declara igual porque el diseño de una
ingesta productiva la necesita, y porque el esquema vacío deja explícito dónde iría.

### 12.2 La circulación

| Etapa | Qué ocurre | Dónde queda |
|---|---|---|
| **Origen** | El curador toma un documento de los repositorios existentes | — |
| **Aterrizaje** | Se calcula el hash del binario y se lo deposita en el almacenamiento de objetos | Almacenamiento de objetos; en la base, URI y hash |
| **Normalización** | Se extrae el texto plano y se registra la versión | `core.documento_version` |
| **Clasificación** | Se asignan tipo, área, nivel, etiquetas, metadatos y otorgamientos de acceso | `core.documento`, `core.acl_documento` |
| **Enriquecimiento** | Se fragmenta el texto y se vectoriza cada fragmento | `core.chunk` |
| **Servicio** | La recuperación devuelve fragmentos ya filtrados; la aplicación se los entrega al modelo | — |
| **Registro** | Se guardan la pregunta, la respuesta, las fuentes citadas y los accesos | `core`, en las tablas particionadas |
| **Análisis** | Se recalculan los indicadores de uso y cobertura | `analytics` |

Las cuatro primeras etapas corresponden a los procesos P1 a P4 del punto 1.5; las tres últimas, a
P5, P7 y P8.

### 12.3 Qué está dentro de la base y qué está fuera

| Componente | Dónde vive | Por qué |
|---|---|---|
| Archivo binario original | Almacenamiento de objetos | Ocupa mucho y no se consulta por su contenido binario (D5) |
| Texto extraído, hash y URI | En la base | El texto se fragmenta y se busca; el hash y la URI lo hacen recuperable y verificable |
| Fragmentación y vectorización | Proceso externo | La base recibe los fragmentos armados; no calcula embeddings |
| Representación de texto completo | En la base | Es una columna generada: la calcula y la mantiene el motor, así que no puede desincronizarse |
| Vectorización de la pregunta | Aplicación | Tiene que usar el mismo modelo y la misma dimensión que la ingesta (R5) |
| Modelo de lenguaje | Fuera del alcance | Caja negra: recibe fragmentos y devuelve texto (1.3) |
| Identidades y credenciales | Sistema de identidad corporativo | La solución consume identidades, no las administra (2.3) |
| **Filtro de permisos** | **Dentro de la base** | **Es la única pieza que no puede mudarse a otro componente sin perder la garantía** |

La última fila es la que ordena toda la arquitectura. Cualquier otro componente podría cambiar de
lugar sin romper el diseño: el almacenamiento de objetos puede ser otro, el proceso de
fragmentación puede reescribirse, el modelo de lenguaje puede reemplazarse. El filtro no, porque
en el momento en que lo aplica algo que no es el motor, deja de ser una garantía y pasa a ser una
convención que hay que recordar respetar en cada consulta nueva.

### 12.4 Dónde se aplica cada garantía

| Garantía | Quién la hace cumplir |
|---|---|
| Un usuario no recupera lo que no está autorizado a ver | Políticas de seguridad por fila, en el motor |
| Un archivo no se procesa ni se vectoriza dos veces | Restricción de unicidad sobre el hash |
| Una respuesta es reconstruible meses después | `respuesta_fuente`, con puntaje y posición |
| Los registros de auditoría no se pueden alterar | Permisos del motor sobre las tablas de solo inserción |
| La capa analítica no filtra texto protegido | Restricción sobre qué puede contener `analytics` |
| Dos vectores de la base son comparables entre sí | Referencia a `modelo_embedding` y dimensión fijada en el tipo |

Ninguna de estas garantías vive en el código de la aplicación. Esa es la definición de
arquitectura que sigue este trabajo: no el dibujo de las cajas, sino la decisión de qué componente
es responsable de que cada cosa no pueda salir mal.

### 12.5 Lo que no se implementa, y por qué

| Pieza | Cuándo correspondería | Por qué no acá |
|---|---|---|
| **Réplica de solo lectura** | Cuando las consultas analíticas empiecen a competir con la recuperación por recursos | El volumen del caso no lo exige, y el trabajo evalúa el diseño de datos y no el despliegue |
| **Orquestación de la ingesta** | Cuando la carga sea continua y haya que reintentar y monitorear | La ingesta acá es un proceso manual del curador sobre un corpus acotado |
| **Almacenamiento de objetos real** | En cualquier despliegue productivo | Se modela como URI y hash: lo que el diseño de datos tiene que resolver es cómo referenciarlo, no cómo montarlo |
| **Alta disponibilidad y recuperación ante desastres** | En producción, por obligación regulatoria | Declarado fuera del alcance en 1.3 |

En los cuatro casos la decisión es la misma: la arquitectura los contempla y los justifica, pero
implementarlos no agregaría nada a la validación del diseño de datos, que es lo que este trabajo
tiene que demostrar.

## 13. Seguridad, permisos y aislamiento

Este punto documenta cómo `05_rls.sql` implementa la decisión D1 y la regla de acceso de 4.4:
qué evalúa el motor, quién puede evaluarlo, y qué le queda deliberadamente fuera de alcance.

### 13.1 De la regla a la política

La regla de 4.4 —nivel del documento por debajo de la habilitación del usuario, y un
otorgamiento vigente que lo alcance salvo nivel público— se traduce en dos funciones SQL,
`core.puede_acceder_documento(documento_id)` y `core.puede_acceder_chunk(documento_version_id)`,
y tres políticas de `SELECT` por tabla (`documento`, `documento_version`, `chunk`), una por cada
rol con un criterio de visibilidad distinto.

**Por qué `documento_version` tiene política propia, y no solo `chunk`.** El borrador de
mecanismos del punto 4 hablaba de proteger "documento y chunk". En la implementación se agregó
`documento_version`, porque su columna `texto` es el contenido completo extraído del documento:
sin política propia, cualquier rol con `SELECT` sobre la tabla lo leería entero sin pasar por la
fragmentación, lo que abre una vía de fuga (R1) distinta de la búsqueda semántica pero
igual de real.

**Por qué son funciones y no la condición inline en la política.** Evaluar la regla de 4.4
requiere consultar `acl_documento` y `usuario_rol`, dos de las tablas más sensibles del modelo
(3.3): `acl_documento` porque "una fila mal puesta expone un documento entero", `usuario_rol`
porque revela la estructura de permisos de la organización. Si la política de `chunk`
consultara esas tablas directamente, `tp_lector` necesitaría `SELECT` sobre ellas para que la
política pudiera evaluarse, y ese `SELECT` sería utilizable también fuera de la política. La
función se declara `SECURITY DEFINER`: corre con los privilegios de quien la creó, no de quien
la invoca, así que `tp_lector` puede invocarla (tiene `EXECUTE`, otorgado explícitamente) sin
tener nunca `SELECT` sobre `acl_documento` ni `usuario_rol`. Es la misma lógica que D1 aplica a
nivel de tabla, aplicada a nivel de función: el motor evalúa el permiso sin exponer los datos
con los que lo evalúa.

Dos detalles de la función importan para su corrección, no solo para su estilo:

- **`SET search_path = core, pg_temp`** fija el `search_path` de la función. Sin esto, una
  función `SECURITY DEFINER` es vulnerable a que quien la invoca redefina un objeto con el
  mismo nombre en un esquema que aparezca antes en su propio `search_path`, y logre que la
  función ejecute código que no es el que su dueño escribió.
- **`REVOKE ALL ... FROM PUBLIC`**, seguido de `GRANT EXECUTE` solo a `tp_lector`. A diferencia
  de las tablas, las funciones nuevas otorgan `EXECUTE` a `PUBLIC` por omisión en PostgreSQL.
  Sin el `REVOKE`, cualquier rol con `USAGE` sobre el esquema `core` podría invocar la función,
  lo que no es un problema de corrección pero sí de disciplina: el `GRANT` explícito documenta
  quién la usa.

### 13.2 Cuatro roles, tres criterios de visibilidad

Los cuatro roles de `02_esquemas_roles.sql` no comparten política porque no cumplen la misma
función (1.4):

| Rol | Visibilidad sobre `documento`/`documento_version`/`chunk` | Por qué |
|---|---|---|
| `tp_lector` | Filtrada por `core.puede_acceder_documento()` / `puede_acceder_chunk()` | Es el rol de conexión de la aplicación RAG: el que hace la búsqueda "ciega al permiso" que D1 tiene que proteger |
| `tp_curador` | Completa (`USING (true)`) | No puede clasificar, versionar ni derogar lo que no ve; sus procesos (P1 a P3) necesitan visibilidad total |
| `tp_auditor` | Completa (`USING (true)`) | "Prácticamente todo el corpus, incluida la documentación derogada... restricciones mínimas, definidas caso por caso" (1.4). Es una decisión de rol, no un caso especial de la regla de 4.4 |
| `tp_admin` | Completa (`USING (true)`) | Administración de la solución; nunca es el rol de conexión de la aplicación |

Que `tp_curador` y `tp_auditor` tengan visibilidad completa no es una excepción a D1: es la
misma idea de RLS aplicada con un criterio distinto por rol, que es exactamente para lo que
PostgreSQL permite declarar varias políticas sobre la misma tabla. El riesgo que D1 ataca es
específico de la búsqueda semántica de la aplicación (R1); un curador o un auditor que
consultan directamente, dentro de su función, no reproducen ese riesgo.

Ningún rol, `tp_lector` incluido, tiene `SELECT` directo sobre `acl_documento` ni
`usuario_rol`. `tp_curador` tiene `SELECT`/`INSERT`/`UPDATE` sobre `acl_documento` —es quien
otorga permisos— pero no `DELETE`: revocar un acceso es cerrar su ventana de vigencia
(`UPDATE` de `vigente_hasta`), no borrar la fila, para no perder el historial de quién tuvo
acceso a qué y hasta cuándo. `tp_auditor` tiene `SELECT` sobre `acl_documento` para poder
auditar otorgamientos, pero ninguna escritura.

### 13.3 El dueño de las tablas

`ALTER TABLE ... FORCE ROW LEVEL SECURITY` se declara sobre las tres tablas protegidas. En este
entorno de Docker no tiene efecto visible, porque `tp_bdia` —el usuario que crea las tablas— se
inicializa como superusuario, y PostgreSQL nunca aplica RLS a un superusuario, con o sin
`FORCE`. Se declara igual porque es lo correcto para un despliegue donde el dueño del esquema
no sea superusuario: sin `FORCE`, el dueño de una tabla ignora sus propias políticas de RLS por
omisión, y esa es exactamente la razón por la que `02_esquemas_roles.sql` advierte, desde antes
de que existiera `05_rls.sql`, que "la aplicación nunca debe conectarse con el rol dueño".

### 13.4 Fail-closed: qué pasa si la aplicación se olvida de declarar el usuario

La aplicación abre la conexión como `tp_lector` y declara quién pregunta con
`SET LOCAL app.usuario_id = <id>` antes de cada consulta. La función de chequeo lee ese valor
con `current_setting('app.usuario_id', true)`, que devuelve `NULL` si no está declarado, en vez
de lanzar un error. Un `NULL` ahí hace que el `JOIN` contra `usuario` no encuentre ninguna fila,
y la función devuelve `false` para todo documento. Es una propiedad deliberada: si un error de
la aplicación olvida declarar el usuario de la sesión, el resultado es que esa sesión no ve
nada, no que vea todo. Un filtro que falla abierto (mostrar de más ante un error) sería
exactamente el tipo de fuga que D1 existe para evitar; este falla cerrado.

Por la misma razón, la garantía no depende de que la consulta esté bien escrita (D1): como el
filtro se evalúa por fila dentro del motor y no en una cláusula `WHERE` que la aplicación arma,
ni una consulta mal construida ni una vulnerable a inyección SQL puede hacer que el motor
devuelva una fila que la política no autoriza. La superficie de ataque se reduce a comprometer
la conexión misma (robar credenciales de `tp_lector` o inyectar un `usuario_id` de sesión que
no corresponde a quien realmente pregunta), que es un problema de la capa de autenticación de
la aplicación y no de la base.

### 13.5 Auditoría y trazabilidad

`log_acceso` y `auditoria` son de solo inserción (RD13), y esa garantía no se implementa con
RLS sino con la ausencia de `GRANT`: ningún rol, `tp_admin` incluido, tiene `UPDATE` ni `DELETE`
sobre ninguna de las dos. Es una decisión deliberada de no dejar excepción para el
administrador: la garantía es que nadie pueda alterarlas desde la aplicación, no que quien
podría elija no hacerlo. Poblar `log_acceso` es responsabilidad de la aplicación (un `INSERT`
por cada acceso resuelto); poblar `auditoria` automáticamente vía disparadores sobre las tablas
sensibles (RD4/RD5, mencionado en 8.2) queda pendiente, y este archivo ya deja el `GRANT`
preparado para cuando existan.

`respuesta_fuente` no tiene política de RLS propia y no la necesita (RD11): la única vía por la
que un fragmento puede llegar a `respuesta_fuente` es que la aplicación lo haya recuperado antes
mediante un `SELECT` sobre `chunk`, que ya pasó por su política. La garantía de RD11 es
consecuencia de la de `chunk`, no una garantía adicional.

### 13.6 Riesgos del punto 1.7 cubiertos por este mecanismo

| Riesgo | Cómo lo ataca este punto |
|---|---|
| R1 — Fuga por recuperación | Políticas de RLS sobre `documento`, `documento_version` y `chunk`, evaluadas por el motor en cada fila |
| R6 — Otorgamientos amplios o vencidos | La función solo considera otorgamientos con `now()` dentro de su ventana de vigencia; uno vencido deja de contar sin que nadie lo borre |
| R7 — Datos personales en consultas | `tp_lector` tiene `INSERT` pero no `SELECT` sobre `consulta`, `respuesta`, `respuesta_fuente` y `feedback`: ningún usuario puede repasar el historial de otro |
| R8 — Derivados sin protección | `analytics.consultas_sin_cobertura` solo expone `consulta.texto`, nunca texto de `chunk` ni de `documento_version`, y no es alcanzable desde `tp_lector` |

### 13.7 Límites de este diseño

- **Aislamiento entre organizaciones.** El modelo aísla usuarios dentro de una misma
  organización; no fue pensado para *multi-tenancy* entre entidades distintas (ver 7.6).
- **La cuenta de servicio compartida.** Nada en este diseño impide que una cuenta de aplicación
  se comparta entre varias personas reales, lo que rompe la trazabilidad de `app.usuario_id`
  hasta la identidad real. Es responsabilidad de la capa de autenticación, no de la base;
  DOC-AUD-003, en el corpus de ejemplo, es precisamente un caso de este tipo de falla.
- **Auditoría automática incompleta.** Sin los disparadores de RD4/RD5, cambios de estado
  documental que deberían quedar en `auditoria` no lo hacen todavía por sí solos.

## 14. Escalabilidad y rendimiento

### 14.1 Qué crece, y con qué

El punto 2.4 distinguió dos regímenes: un catálogo documental grande pero estable (`documento`,
`documento_version`, `chunk`), que crece con la organización, y las tablas de eventos
(`consulta`, `respuesta`, `respuesta_fuente`, `log_acceso`, `auditoria`), que crecen sin límite
con el uso. Ese régimen distinto es la razón de que solo el segundo grupo esté particionado
(5.3) y de que este punto trate cada uno con una estrategia distinta.

### 14.2 Particionado: qué se implementó y qué se analiza

Se implementó el particionado declarativo por rango mensual sobre `creado_en` (5.4, 8.1) con
doce particiones de 2026 más una partición `DEFAULT`. Lo que da escalabilidad no es la
existencia de las particiones en sí, sino la **poda de particiones**: una consulta acotada por
fecha (`WHERE creado_en >= '2026-06-01'`) solo toca las particiones que pueden contener esa
fecha, y el resto ni se abre. Como casi todas las consultas sobre estas tablas se acotan por
fecha en la práctica (informe 2.4: "casi siempre se consultan acotadas por fecha"), la poda es
la regla y no la excepción.

Lo que se analiza y no se construye, siguiendo la aclaración de la cátedra:

- **Creación automática de particiones futuras.** En producción, una partición para el mes
  siguiente se crea con antelación mediante un job programado o la extensión `pg_partman`, no a
  mano cada vez. La partición `DEFAULT` es la red de seguridad mientras tanto: una fila fuera
  del rango declarado no rechaza el `INSERT`, cae ahí, y su acumulación es la señal de que hace
  falta extender el rango.
- **Purga por partición.** Una vez definida la política de retención (14.7), eliminar datos
  vencidos es `DROP TABLE` de la partición completa, sin `DELETE` fila por fila ni el
  `VACUUM` posterior que un borrado masivo exige. Es el motivo principal por el que estas
  tablas están particionadas, más allá de la poda en las lecturas.
- **Réplica de solo lectura.** Separar las consultas analíticas (`analytics`) de la carga
  transaccional (`core`) en una réplica es la respuesta cuando ambas empiecen a competir por
  recursos (12.5). El volumen del caso, estimado en 2.4, no lo exige todavía.

### 14.3 Índices: qué consulta resuelve cada uno

Cada índice de `db/indices_vistas/01_indices.sql` se justifica contra una pregunta concreta del
relevamiento (2.2), no contra una regla genérica de "indexar las claves foráneas":

| Índice | Consulta que resuelve | Por qué esa estructura |
|---|---|---|
| `idx_chunk_embedding_hnsw` | Búsqueda semántica (camino crítico) | HNSW no necesita reconstruirse cuando cambia el volumen de datos, a diferencia de IVFFlat, cuyo número de listas se fija en función del tamaño de la tabla al crearlo. El costo es un `build` más lento y más memoria, aceptable para el volumen de 2.4 |
| `idx_chunk_tsv_gin` | Términos exactos, mitad léxica de la recuperación híbrida con RRF | GIN es la estructura estándar de PostgreSQL para `tsvector` |
| `idx_documento_titulo_trgm` | Tolerancia a errores de tipeo en el título (interfaz del curador) | `pg_trgm` compara por trigramas, no por coincidencia exacta ni por prefijo |
| `idx_documento_metadatos_gin` | Filtrado por atributos variables de `documento.metadatos` (D6) | Sin este índice, cualquier filtro por `JSONB` degrada a recorrido secuencial completo |
| `idx_documento_estado` | Filtro de vigencia (D3), presente en cada consulta del camino crítico | Cardinalidad baja (cuatro valores) por sí sola, pero combina en un *bitmap AND* con los índices anteriores en vez de forzar el recorrido secuencial |
| `idx_acl_documento_documento_id` | El `EXISTS` por `documento_id` dentro de `core.puede_acceder_documento()` (13.1) | Es el índice del que depende el costo de evaluar RLS en cada fila: sin él, cada chequeo de acceso recorre `acl_documento` entera |
| `idx_consulta_usuario_id` | Uso por usuario/área (2.2) | Se declara sobre la tabla particionada y PostgreSQL la propaga a cada partición existente y futura (5.3) |
| `idx_respuesta_fuente_chunk_id` | Documentos más citados como fuente (2.1.F) | — |
| `idx_log_acceso_documento_id` | Quién accedió a un documento dado (2.2) | — |
| `idx_auditoria_entidad` | Historial de cambios de una fila puntual, por ejemplo un otorgamiento (2.2) | Compuesto `(entidad, entidad_id)`: identifica una fila de cualquier tabla auditada sin necesitar una clave foránea (6.3, la excepción deliberada de `auditoria`) |

El de mayor impacto sobre el diseño de seguridad, más que sobre una consulta de negocio
puntual, es `idx_acl_documento_documento_id`: el costo de D1 —evaluar el permiso en cada fila
que la búsqueda semántica considera candidata— es, en la práctica, el costo de este índice.

### 14.4 Capa analítica: una vista construida, tres analizadas

`analytics.consultas_sin_cobertura` (8.1) es la única de las cuatro vistas de 2.1.F que se
construye. Lleva además un índice único sobre `consulta_id`, no por una consulta que lo
necesite sino porque es el requisito de PostgreSQL para poder usar
`REFRESH MATERIALIZED VIEW CONCURRENTLY`, que no bloquea las lecturas mientras se recalcula.
Importa acá y no en el punto 8 porque la vista se recalcula sobre `consulta`, la tabla de mayor
volumen de escritura del sistema (2.4): un refresco que bloqueara esa tabla mientras se
recalcula competiría directamente con el tráfico que el sistema tiene que priorizar.

Las otras tres —documentos más citados, uso por área, antigüedad de lo consultado— son
agregaciones del mismo tipo sobre las mismas tablas de eventos, y su costo de refresco escala
con el mismo volumen. Se describen y se justifican en 2.1.F sin construirse: no agregan nada
nuevo a la validación del diseño físico que ya demuestra la que sí se construyó.

### 14.5 Política de retención (propuesta)

El punto 2.4 identificó que las tablas de eventos necesitan una política de retención, y quedó
como duda abierta del equipo. Se propone acá, para que el punto quede cubierto, a validar entre
los tres antes de la entrega:

| Tabla | Retención propuesta | Motivo |
|---|---|---|
| `consulta`, `respuesta`, `respuesta_fuente` | 24 meses en detalle, agregados de `analytics` sin límite después | Contienen posibles datos personales (R7); 24 meses cubre dos ciclos de auditoría interna sin acumular indefinidamente texto de preguntas |
| `feedback` | Igual que `respuesta`, por la relación de clave foránea entre ambas | — |
| `log_acceso`, `auditoria` | 6 años | Alineado con plazos habituales de conservación de registros en entidades financieras reguladas por el BCRA; son las tablas que sostienen una reconstrucción ante un requerimiento regulatorio |

La purga, una vez fijada esta política, es `DROP TABLE` sobre las particiones vencidas (14.2),
no un `DELETE` masivo.

### 14.6 Consultas críticas y consultas de análisis

La distinción de 2.2 entre camino crítico (búsqueda semántica, términos exactos, trazabilidad
de una respuesta, filtrado por permiso) y consultas de análisis o auditoría se traduce
directamente en dónde se invierte en rendimiento: los índices de 14.3 que sostienen el camino
crítico (HNSW, GIN, `idx_documento_estado`, `idx_acl_documento_documento_id`) tienen que
mantener baja latencia siempre; los que sostienen agregaciones (`idx_consulta_usuario_id`,
`idx_respuesta_fuente_chunk_id`) y la vista materializada pueden tolerar más latencia o un
resultado desfasado, porque nadie espera una respuesta de eso en el momento en que hace una
pregunta.

### 14.7 Límites de este diseño

- **HNSW compite con la carga transaccional por memoria** a partir de varias decenas de
  millones de fragmentos con alta concurrencia de búsqueda (7.6): ahí se reevaluaría separar la
  recuperación en un motor dedicado.
- **La partición `DEFAULT` no escala como sustituto de particiones explícitas.** Si acumula
  volumen relevante, el `EXPLAIN` deja de poder podarla y el problema que el particionado
  resuelve vuelve a aparecer dentro de esa única partición.
- **Este diseño no resuelve alta disponibilidad ni recuperación ante desastres** (12.5):
  particiona y precalcula para rendimiento, no para continuidad operativa.

## 15. Conclusiones

*(Pendiente — los tres.)*
