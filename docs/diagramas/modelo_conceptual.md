# Modelo conceptual

Diagrama entidad-relación del sistema RAG para consulta de documentación técnica. Corresponde al
punto 4 del [informe](../informe.md), donde se justifican las entidades, las cardinalidades y las
restricciones del dominio.

Los diagramas están escritos en Mermaid para poder versionarlos y ver los cambios en los *diffs*.
Se exportan a `.png` al cierre del trabajo.

## Notación

Las entidades son rectángulos con sus atributos; las relaciones, rombos. Sobre cada línea va la
cardinalidad de la entidad que tiene al lado: `1` si participa una sola instancia, `N` si
participan varias. `area 1 — agrupa a — N usuario` se lee «un área agrupa a N usuarios» y «un
usuario pertenece a un área».

El atributo que identifica a la entidad lleva `(id)`. No se dibujan claves foráneas: la
dependencia ya la expresa la relación. Las entidades sin `(id)` se identifican por un sustituto o
por una relación —el orden de un fragmento dentro de su versión, por ejemplo—; el identificador
completo de cada una está en la tabla del punto 4.2 del informe.

Las entidades ya detalladas en un diagrama anterior reaparecen en los siguientes sin atributos,
para mostrar las relaciones que cruzan de un bloque a otro.

---

## Vista general

Las tres zonas del modelo: quién puede ver qué, qué documentación existe, y qué se hizo con ella.

```mermaid
flowchart LR
    area[area]
    usuario[usuario]
    rol[rol]
    permiso[permiso]
    nivel[nivel_confidencialidad]
    acl[acl_documento]
    tipo[tipo_documento]
    documento[documento]
    version[documento_version]
    relacion[documento_relacion]
    etiqueta[etiqueta]
    chunk[chunk]
    modelo[modelo_embedding]
    consulta[consulta]
    respuesta[respuesta]
    fuente[respuesta_fuente]
    feedback[feedback]
    acceso[log_acceso]
    auditoria[auditoria]

    area ---|1| rAgrupa{agrupa a}
    rAgrupa ---|N| usuario

    nivel ---|1| rHabilita{habilita hasta}
    rHabilita ---|N| usuario

    usuario ---|N| rDesempena{desempeña}
    rDesempena ---|N| rol

    rol ---|N| rConcede{concede}
    rConcede ---|N| permiso

    documento ---|1| rOtorga{se otorga en}
    rOtorga ---|N| acl

    area ---|1| rSujetoArea{es sujeto de}
    rSujetoArea ---|N| acl

    rol ---|1| rSujetoRol{es sujeto de}
    rSujetoRol ---|N| acl

    usuario ---|1| rSujetoUsuario{es sujeto de}
    rSujetoUsuario ---|N| acl

    area ---|1| rPropietaria{es propietaria de}
    rPropietaria ---|N| documento

    nivel ---|1| rClasifica{clasifica}
    rClasifica ---|N| documento

    tipo ---|1| rTipifica{tipifica}
    rTipifica ---|N| documento

    documento ---|1| rPublica{se publica como}
    rPublica ---|N| version

    documento ---|1| rOrigen{es origen de}
    rOrigen ---|N| relacion

    documento ---|1| rDestino{es destino de}
    rDestino ---|N| relacion

    documento ---|N| rEtiqueta{se clasifica con}
    rEtiqueta ---|N| etiqueta

    version ---|1| rFragmenta{se fragmenta en}
    rFragmenta ---|N| chunk

    modelo ---|1| rVectoriza{vectoriza}
    rVectoriza ---|N| chunk

    usuario ---|1| rFormula{formula}
    rFormula ---|N| consulta

    consulta ---|1| rProduce{produce}
    rProduce ---|1| respuesta

    respuesta ---|1| rApoya{se apoya en}
    rApoya ---|N| fuente

    chunk ---|1| rCitado{es citado en}
    rCitado ---|N| fuente

    respuesta ---|1| rRecibe{recibe}
    rRecibe ---|N| feedback

    usuario ---|1| rDeja{deja}
    rDeja ---|N| feedback

    usuario ---|1| rGenera{genera}
    rGenera ---|N| acceso

    documento ---|1| rAccedido{es accedido en}
    rAccedido ---|N| acceso

    usuario ---|1| rEjecuta{ejecuta}
    rEjecuta ---|N| auditoria
```

---

## Organización y control de acceso

Quién es cada usuario y qué documentación puede alcanzar. `acl_documento` expresa el
otorgamiento como una relación entre un documento y un sujeto, que puede ser un área, un rol o
un usuario individual.

```mermaid
flowchart LR
    area["area<br/>———<br/>nombre (id)<br/>descripcion"]
    usuario["usuario<br/>———<br/>identificador_corporativo (id)<br/>nombre<br/>correo<br/>activo<br/>fecha_alta"]
    rol["rol<br/>———<br/>nombre (id)<br/>descripcion"]
    permiso["permiso<br/>———<br/>codigo (id)<br/>descripcion"]
    nivel["nivel_confidencialidad<br/>———<br/>nombre (id)<br/>orden<br/>(publico 1, interno 2,<br/>confidencial 3, restringido 4)"]
    acl["acl_documento<br/>———<br/>vigente_desde<br/>vigente_hasta<br/>motivo"]
    documento[documento]

    area ---|1| rAgrupa{agrupa a}
    rAgrupa ---|N| usuario

    nivel ---|1| rHabilita{habilita hasta}
    rHabilita ---|N| usuario

    usuario ---|N| rDesempena{desempeña}
    rDesempena ---|N| rol

    rol ---|N| rConcede{concede}
    rConcede ---|N| permiso

    documento ---|1| rOtorga{se otorga en}
    rOtorga ---|N| acl

    area ---|1| rSujetoArea{es sujeto de}
    rSujetoArea ---|N| acl

    rol ---|1| rSujetoRol{es sujeto de}
    rSujetoRol ---|N| acl

    usuario ---|1| rSujetoUsuario{es sujeto de}
    rSujetoUsuario ---|N| acl

    usuario ---|1| rOtorgante{otorga}
    rOtorgante ---|N| acl
```

Las tres relaciones «es sujeto de» son excluyentes entre sí: cada otorgamiento tiene un sujeto y
uno solo (restricción RD7 del informe). Es el arco exclusivo que el punto 4.6 deja abierto para
el modelo lógico.

---

## Documentación y contenido

El catálogo, su historial de versiones y el contenido fragmentado que alimenta la recuperación.

```mermaid
flowchart LR
    tipo["tipo_documento<br/>———<br/>nombre (id)<br/>descripcion"]
    documento["documento<br/>———<br/>codigo (id)<br/>titulo<br/>estado (borrador, vigente,<br/>obsoleto, derogado)<br/>metadatos"]
    version["documento_version<br/>———<br/>numero_version (id)<br/>vigente_desde<br/>vigente_hasta<br/>hash_sha256<br/>uri_original<br/>texto_extraido<br/>publicada_en"]
    relacion["documento_relacion<br/>———<br/>tipo (deroga, reemplaza,<br/>complementa, referencia)<br/>fecha_efecto"]
    etiqueta["etiqueta<br/>———<br/>nombre (id)"]
    chunk["chunk<br/>———<br/>orden (id)<br/>contenido<br/>cantidad_tokens<br/>seccion<br/>embedding<br/>metadatos"]
    modelo["modelo_embedding<br/>———<br/>nombre (id)<br/>dimension<br/>vigente_desde"]
    area[area]
    nivel[nivel_confidencialidad]

    tipo ---|1| rTipifica{tipifica}
    rTipifica ---|N| documento

    area ---|1| rPropietaria{es propietaria de}
    rPropietaria ---|N| documento

    nivel ---|1| rClasifica{clasifica}
    rClasifica ---|N| documento

    documento ---|1| rPublica{se publica como}
    rPublica ---|N| version

    documento ---|1| rOrigen{es origen de}
    rOrigen ---|N| relacion

    documento ---|1| rDestino{es destino de}
    rDestino ---|N| relacion

    documento ---|N| rEtiqueta{se clasifica con}
    rEtiqueta ---|N| etiqueta

    version ---|1| rFragmenta{se fragmenta en}
    rFragmenta ---|N| chunk

    modelo ---|1| rVectoriza{vectoriza}
    rVectoriza ---|N| chunk
```

Los fragmentos cuelgan de la versión y no del documento (decisión D2): de esa pertenencia
heredan la vigencia y el nivel de confidencialidad, que no se guardan en el fragmento.

---

## Uso del sistema y auditoría

Qué se preguntó, qué se respondió y con qué material. `respuesta_fuente` es la entidad que
responde al requisito de registrar qué documentación se usó para construir cada respuesta.

```mermaid
flowchart LR
    consulta["consulta<br/>———<br/>texto_pregunta<br/>embedding_pregunta<br/>momento<br/>latencia_ms"]
    respuesta["respuesta<br/>———<br/>texto_generado<br/>modelo_lenguaje<br/>tokens_generados<br/>confianza<br/>momento"]
    fuente["respuesta_fuente<br/>———<br/>puntaje<br/>posicion"]
    feedback["feedback<br/>———<br/>util<br/>comentario<br/>momento"]
    acceso["log_acceso<br/>———<br/>resultado (concedido, denegado)<br/>momento"]
    auditoria["auditoria<br/>———<br/>entidad_afectada<br/>id_entidad_afectada<br/>accion (alta, baja, modificacion)<br/>valor_anterior<br/>valor_nuevo<br/>momento"]
    usuario[usuario]
    chunk[chunk]
    documento[documento]

    usuario ---|1| rFormula{formula}
    rFormula ---|N| consulta

    consulta ---|1| rProduce{produce}
    rProduce ---|1| respuesta

    respuesta ---|1| rApoya{se apoya en}
    rApoya ---|N| fuente

    chunk ---|1| rCitado{es citado en}
    rCitado ---|N| fuente

    respuesta ---|1| rRecibe{recibe}
    rRecibe ---|N| feedback

    usuario ---|1| rDeja{deja}
    rDeja ---|N| feedback

    usuario ---|1| rGenera{genera}
    rGenera ---|N| acceso

    documento ---|1| rAccedido{es accedido en}
    rAccedido ---|N| acceso

    consulta ---|1| rOrigina{origina}
    rOrigina ---|N| acceso

    usuario ---|1| rEjecuta{ejecuta}
    rEjecuta ---|N| auditoria
```

`auditoria` no tiene relación con la entidad que audita: la identifica por nombre y por
identificador, sin integridad referencial. Es deliberado, porque el registro tiene que sobrevivir
a la baja de aquello que audita. Con una clave foránea, borrar un otorgamiento de acceso borraría
también la constancia de que existió.
