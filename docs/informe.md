# Informe técnico

**Trabajo Práctico Integrador — Bases de Datos para IA**
**Caso 1 — Sistema RAG para consulta de documentación técnica**

Integrantes: Martin Birman · Gonzalo Castro · Hernando Schidl

---

## Contenido

1. [Descripción del caso de uso](#1-descripción-del-caso-de-uso)
2. [Relevamiento de datos necesarios](#2-relevamiento-de-datos-necesarios)
3. Clasificación de los datos
4. Modelo conceptual
5. Modelo de implementación
6. Normalización y desnormalización
7. Justificación de la tecnología
8. Implementación mínima
9. Datos de ejemplo
10. Consultas representativas
11. Datos semiestructurados, no estructurados y vectoriales
12. Arquitectura de datos
13. Seguridad, permisos y aislamiento
14. Escalabilidad y rendimiento
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

La solución propuesta es un sistema RAG (*Retrieval-Augmented Generation*): un sistema que
recupera de una base los fragmentos de documentación más relevantes para una pregunta escrita en
lenguaje natural, y se los entrega a un modelo de lenguaje para que redacte la respuesta
**usando solamente ese material**, citando de dónde salió cada afirmación.

Esto define dos flujos de datos con exigencias muy distintas. La **ingesta** es un proceso de
escritura, poco frecuente y controlado: se carga un documento, se lo clasifica, se lo parte en
fragmentos, se representa cada fragmento como un vector numérico y se almacena todo. La
**consulta** es un proceso de lectura, frecuente y sensible a la latencia: se convierte la
pregunta al mismo espacio vectorial, se recuperan los fragmentos más cercanos y se registra qué
se recuperó y qué se respondió.

### 1.2 Contexto: una entidad financiera regulada

El caso se ambienta en un banco de tamaño medio sujeto a regulación. El dominio no es
decorativo: es el que hace que las restricciones del problema aparezcan con naturalidad, porque
allí conviven todos los tipos de documentación que el sistema debe manejar.

| Tipo de documentación | Característica que aporta al caso |
|---|---|
| Normativa externa del regulador (BCRA) | Cambia con frecuencia; las versiones viejas quedan derogadas pero deben conservarse |
| Políticas internas (riesgo crediticio, prevención de lavado, seguridad de la información) | Acceso restringido por área y por nivel de confidencialidad |
| Procedimientos operativos de sucursal y de *back office* | Alto volumen de consulta, muchas versiones, público amplio |
| Manuales técnicos del core bancario y sistemas satélite | Contenido sensible desde el punto de vista de la seguridad informática |
| Preguntas frecuentes | Conocimiento hoy informal, respondido a mano por gente con experiencia |
| Informes de investigación (fraude interno, casos reportados) | El caso extremo de acceso restringido |
| Documentación histórica derogada | Debe conservarse por obligación regulatoria y **no debe usarse para responder** |

En una organización así es evidente por qué un analista de sucursal no puede leer el informe de
una investigación de fraude interno, ni el manual de configuración del core bancario. Y es
evidente también por qué contestar con un procedimiento derogado no es un error menor: puede
constituir un incumplimiento regulatorio.

Para poder estimar volúmenes y justificar decisiones de escalabilidad, se toma como referencia
una organización de aproximadamente 4.000 empleados, de los cuales unos 1.500 son usuarios
efectivos del sistema, distribuidos en 6 áreas, con del orden de 20.000 documentos vigentes y
unas 45.000 versiones acumuladas contando el histórico. Estos números son un supuesto de
trabajo explícito, y se retoman en el punto 2.4 y en el punto 14.

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
fragmentos, y devuelve texto. La frontera entre el modelo y la solución de datos es precisa, y
conviene fijarla desde el principio porque de ella dependen varias decisiones posteriores:

1. La base entrega al modelo **únicamente** fragmentos que el usuario que pregunta está
   autorizado a ver y que pertenecen a documentación vigente.
2. El modelo redacta con ese material.
3. La base registra qué fragmentos se entregaron, con qué puntaje y en qué orden, junto con la
   respuesta producida.

Todo lo que ocurre entre los pasos 1 y 3 es responsabilidad del modelo. Todo lo que lo habilita
y lo que queda registrado es responsabilidad del diseño de datos.

### 1.4 Usuarios

El sistema tiene dos clases de usuario con necesidades opuestas: quienes **consultan** y quienes
**mantienen** la documentación. La tabla siguiente describe los perfiles considerados; la
columna de la derecha es tan importante como la del medio, porque es la que define el problema
central del caso.

| Perfil | Qué consulta | Qué no debe poder ver |
|---|---|---|
| Analista de sucursal (Operaciones) | Procedimientos operativos, instructivos de atención, preguntas frecuentes | Manuales técnicos del core, informes de investigación, políticas de nivel restringido |
| Oficial de riesgo crediticio (Riesgos) | Políticas de riesgo, normativa del regulador, criterios de otorgamiento | Informes de investigación de fraude, documentación técnica de sistemas |
| Analista de prevención de lavado (Compliance) | Normativa, políticas de prevención, procedimientos de reporte, informes de casos de su alcance | Documentación técnica de sistemas, políticas de otras áreas de nivel confidencial |
| Administrador de sistemas (Tecnología) | Manuales técnicos, guías de configuración, procedimientos de contingencia | Informes de investigación, documentación de negocio de nivel restringido |
| Auditor interno (Auditoría Interna) | Prácticamente todo el corpus, **incluida la documentación derogada** y los registros de auditoría del propio sistema | Restricciones mínimas, definidas caso por caso |
| Abogado (Legales) | Normativa, contratos marco, dictámenes, políticas | Documentación técnica de sistemas |
| Curador documental | No consulta para obtener respuestas: carga, clasifica, versiona, publica y deroga documentos, y asigna sus permisos | — |

De este relevamiento de perfiles se desprenden dos observaciones que condicionan el modelo de
datos y que no son obvias a primera vista:

**El permiso no es un atributo del usuario ni del documento, sino de la relación entre ambos.**
Un mismo informe de investigación es visible para Compliance y para Auditoría Interna, e
invisible para el resto; un mismo manual técnico es visible para Tecnología y no para Riesgos.
No alcanza con un nivel de habilitación por usuario ni con una etiqueta por documento: hace
falta una entidad que exprese explícitamente el otorgamiento, y que pueda hacerlo a nivel de
área, de rol o de usuario individual.

**La vigencia y el permiso son dos ejes independientes.** El auditor interno es el caso que lo
demuestra: necesita consultar deliberadamente documentación derogada, que para todos los demás
perfiles no debe alimentar ninguna respuesta. Un documento derogado no es un documento
inaccesible, es un documento excluido de la recuperación por defecto. Confundir ambas cosas —
por ejemplo, resolviendo la vigencia con las mismas reglas que el acceso — haría imposible el
caso de uso de auditoría, que es precisamente el que justifica conservar el histórico.

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

Un detalle de este proceso que conviene subrayar: **la restricción por permisos no la aplica el
proceso de consulta**. La aplica el motor de base de datos, por debajo, de manera que ninguna
consulta pueda omitirla. El desarrollo de este mecanismo corresponde al punto 13.

**P6 — Realimentación.** El usuario indica si la respuesta le resultó útil y puede dejar un
comentario. Es el insumo para detectar documentación deficiente o faltante.

**P7 — Auditoría.** Cada acceso a un documento, cada cambio de permisos y cada cambio de estado
documental se registra de manera permanente y no modificable.

**P8 — Análisis de uso.** Sobre los registros acumulados se calculan indicadores: qué se
consulta, qué documentación se cita más, qué preguntas no encuentran respuesta.

La siguiente tabla resume la circulación de datos entre procesos, y es el puente hacia el
relevamiento del punto 2: todo dato que la solución almacene debe tener un proceso que lo
produzca y al menos uno que lo consuma.

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
consulta convencional, acá el modelo **redacta con ese contenido**: aunque el documento nunca se
muestre en pantalla, la respuesta filtra lo que decía. El daño no requiere que el usuario vea el
documento; le alcanza con que el fragmento haya entrado al contexto del modelo.

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

Las decisiones que siguen se toman en este punto porque se desprenden del análisis del caso, y
no de la tecnología elegida. Cada una se desarrolla y se justifica en detalle más adelante.

**D1 — El control de acceso vive dentro del motor de base de datos, no en la aplicación.** Si el
filtro de permisos lo aplicara el código que consulta, bastaría una consulta mal escrita, un
recuperador nuevo o un script de análisis para producir una fuga. Al resolverlo en el motor, el
sistema no puede devolver una fila prohibida **ni aunque la consulta esté mal escrita**. Es la
única forma de que la ceguera al permiso de la búsqueda por similitud (R1) deje de ser un
problema: el recuperador puede ser ciego, porque el motor no lo es.

**D2 — Los fragmentos pertenecen a la versión del documento, no al documento.** Si colgaran del
documento, al publicar una versión nueva habría que decidir qué hacer con los fragmentos
anteriores, y en cualquiera de los caminos posibles se pierde la capacidad de reconstruir con
qué texto exacto se respondió una consulta de hace seis meses. Es la decisión que hace posible
R3 y la que permite conservar el histórico sin contaminar la recuperación.

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
El relevamiento se hizo por proceso — cada dato listado tiene un proceso de 1.5 que lo produce y
al menos uno que lo consume — y se controló después contra los riesgos de 1.7, para verificar
que ninguno quedara sin datos que permitan mitigarlo.

Los nombres que se usan acá son los que después toman las entidades del modelo conceptual
(punto 4), para que no haya que traducir entre un punto y otro del informe.

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

Los metadatos de posición del fragmento cumplen una función concreta en la respuesta: permiten
citar «sección 4.2 del procedimiento», y no solo el documento entero.

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
tabla que ya crece rápido. Es una decisión con impacto en el punto 14.

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
cómo. Cada pregunta de esta lista es respondible con los datos identificados en 2.1.

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

Las tres primeras y la quinta son consultas del camino crítico de la aplicación: se ejecutan en
cada pregunta y su latencia es la latencia percibida del sistema. Las demás son de análisis o de
auditoría, con exigencias de tiempo de respuesta mucho más laxas. Esta distinción es la que
después determina qué se indexa y qué se precalcula (punto 14).

### 2.3 Datos que deliberadamente quedan fuera de la base

| Dato | Dónde vive | Por qué |
|---|---|---|
| Archivo original (PDF, ofimática) | Almacenamiento de objetos; en la base, URI + hash + texto extraído | Ocupa mucho, no se consulta por su contenido binario y no aporta a la recuperación |
| Credenciales de los usuarios | Sistema de identidad corporativo | La solución consume identidades, no las administra; guardar contraseñas sería asumir un riesgo ajeno al caso |
| Pesos y parámetros del modelo de lenguaje | Fuera del alcance (1.3) | El modelo es una caja negra |
| Contenido de las respuestas descartadas por el usuario antes de enviarlas | No se registra | No hay proceso que lo consuma |

### 2.4 Volumen, crecimiento y retención

Estimaciones sobre la organización de referencia de 1.2, como insumo del punto 14. El objetivo
no es la precisión sino distinguir **qué crece con la organización y qué crece con el uso**, que
son dos regímenes completamente distintos.

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

La conclusión operativa del relevamiento es que hay dos grupos de datos con exigencias opuestas.
El catálogo documental y sus fragmentos son grandes pero estables, y se optimizan para lectura.
Las tablas de eventos —consultas, respuestas, fuentes, accesos y auditoría— crecen de forma
indefinida con el uso, se escriben mucho más de lo que se leen y casi siempre se consultan
acotadas por fecha. Esa diferencia es la que justifica tratarlas con una estrategia de
almacenamiento distinta, que se desarrolla en el punto 14.

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

*(Pendiente — Gonzalo.)*

## 4. Modelo conceptual

*(Pendiente — Gonzalo.)*

## 5. Modelo de implementación

*(Pendiente — Gonzalo.)*

## 6. Normalización y desnormalización

*(Pendiente — Gonzalo.)*

## 7. Justificación de la tecnología

*(Pendiente — a asignar.)*

## 8. Implementación mínima

*(Pendiente — Martin.)*

## 9. Datos de ejemplo

*(Pendiente — Hernando.)*

## 10. Consultas representativas

*(Pendiente — Hernando.)*

## 11. Datos semiestructurados, no estructurados y vectoriales

*(Pendiente — Hernando.)*

## 12. Arquitectura de datos

*(Pendiente — Gonzalo y Martin.)*

## 13. Seguridad, permisos y aislamiento

*(Pendiente — Martin.)*

## 14. Escalabilidad y rendimiento

*(Pendiente — Martin.)*

## 15. Conclusiones

*(Pendiente — los tres.)*
