-- =============================================================================
-- 03 - Tablas y restricciones
-- =============================================================================
-- Implementa el modelo relevado en el informe (punto 2). Las decisiones de diseno
-- que se materializan aca son las de 1.8:
--
--   D2  los fragmentos cuelgan de la version, no del documento
--   D3  vigencia y permiso son ejes independientes
--   D4  cada respuesta guarda que fragmentos la originaron
--   D5  el archivo original no se almacena: URI + hash + texto extraido
--   D6  los metadatos variables por tipo de documento van en JSONB
--
-- Las tablas de eventos se declaran particionadas por rango de fecha. Sus
-- particiones se crean en 04_particiones.sql: sin ellas la tabla existe pero no
-- acepta inserciones, que es el comportamiento buscado (obliga a que el
-- mantenimiento de particiones sea explicito).
-- =============================================================================

SET search_path = core, public;


-- =============================================================================
-- A. Estructura organizativa y control de acceso
-- =============================================================================

CREATE TABLE area (
    id              integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre          text        NOT NULL UNIQUE,
    descripcion     text,
    activa          boolean     NOT NULL DEFAULT true,
    creado_en       timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT area_nombre_no_vacio CHECK (length(trim(nombre)) > 0)
);
COMMENT ON TABLE area IS 'Unidades organizativas del banco. Cambia muy poco y es la unidad mas habitual de otorgamiento de permisos.';


CREATE TABLE rol (
    id              integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre          text        NOT NULL UNIQUE,
    descripcion     text,
    CONSTRAINT rol_nombre_no_vacio CHECK (length(trim(nombre)) > 0)
);
COMMENT ON TABLE rol IS 'Funciones que agrupan permisos: consultor, curador, auditor, administrador.';


CREATE TABLE permiso (
    id              integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    codigo          text        NOT NULL UNIQUE,
    descripcion     text        NOT NULL,
    CONSTRAINT permiso_codigo_formato CHECK (codigo ~ '^[a-z][a-z0-9_.]*$')
);
COMMENT ON TABLE permiso IS 'Acciones habilitadas sobre el sistema (consultar, cargar, publicar, derogar, auditar).';


CREATE TABLE rol_permiso (
    rol_id          integer NOT NULL REFERENCES rol(id)     ON DELETE CASCADE,
    permiso_id      integer NOT NULL REFERENCES permiso(id) ON DELETE CASCADE,
    PRIMARY KEY (rol_id, permiso_id)
);
COMMENT ON TABLE rol_permiso IS 'Relacion muchos a muchos entre roles y permisos.';


CREATE TABLE usuario (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    -- Identificador en el sistema de identidad corporativo. La solucion consume
    -- identidades, no las administra: aca no se guardan credenciales (informe 2.3).
    identidad_ext   text        NOT NULL UNIQUE,
    nombre          text        NOT NULL,
    email           text        NOT NULL UNIQUE,
    area_id         integer     NOT NULL REFERENCES area(id),
    activo          boolean     NOT NULL DEFAULT true,
    creado_en       timestamptz NOT NULL DEFAULT now(),
    baja_en         timestamptz,
    CONSTRAINT usuario_email_formato CHECK (email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
    -- Baja logica: el usuario no se borra porque sus consultas y accesos deben
    -- seguir siendo auditables.
    CONSTRAINT usuario_baja_coherente CHECK ((activo AND baja_en IS NULL) OR (NOT activo AND baja_en IS NOT NULL))
);
COMMENT ON TABLE usuario IS 'Personas que usan el sistema. Contiene datos personales (R7): nombre y correo son datos sensibles.';
COMMENT ON COLUMN usuario.identidad_ext IS 'Identificador en el sistema de identidad corporativo.';


CREATE TABLE usuario_rol (
    usuario_id      bigint  NOT NULL REFERENCES usuario(id) ON DELETE CASCADE,
    rol_id          integer NOT NULL REFERENCES rol(id)     ON DELETE CASCADE,
    otorgado_en     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (usuario_id, rol_id)
);
COMMENT ON TABLE usuario_rol IS 'Un usuario puede tener mas de un rol (por ejemplo, consultor y curador de su area).';


CREATE TABLE nivel_confidencialidad (
    id              smallint    PRIMARY KEY,
    nombre          text        NOT NULL UNIQUE,
    -- Escala ordenada: quien alcanza un nivel alcanza tambien los inferiores.
    -- Decidido en el relevamiento (informe 2.1.A).
    orden           smallint    NOT NULL UNIQUE,
    descripcion     text,
    CONSTRAINT nivel_orden_positivo CHECK (orden > 0)
);
COMMENT ON TABLE nivel_confidencialidad IS 'Escala ordenada: publico < interno < confidencial < restringido. El orden es lo que permite expresar el acceso como comparacion y no como enumeracion.';


CREATE TABLE acl_documento (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    documento_id    bigint      NOT NULL,   -- FK declarada mas abajo (dependencia circular con documento)
    -- El otorgamiento se expresa en una de tres granularidades, nunca en mas de
    -- una a la vez. Es la entidad que materializa la observacion de 1.4: el
    -- permiso es una propiedad de la relacion usuario-documento.
    area_id         integer     REFERENCES area(id)    ON DELETE CASCADE,
    rol_id          integer     REFERENCES rol(id)     ON DELETE CASCADE,
    usuario_id      bigint      REFERENCES usuario(id) ON DELETE CASCADE,
    -- Ventana de vigencia del permiso (R6): un permiso transitorio solo caduca
    -- si tiene fecha de fin registrada.
    vigente_desde   timestamptz NOT NULL DEFAULT now(),
    vigente_hasta   timestamptz,
    otorgado_por    bigint      NOT NULL REFERENCES usuario(id),
    creado_en       timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT acl_una_sola_granularidad CHECK (num_nonnulls(area_id, rol_id, usuario_id) = 1),
    CONSTRAINT acl_vigencia_coherente    CHECK (vigente_hasta IS NULL OR vigente_hasta > vigente_desde)
);
COMMENT ON TABLE acl_documento IS 'Otorgamiento de acceso a un documento, por area, rol o usuario, con ventana de vigencia. Es la tabla mas critica del modelo: de ella dependen las politicas de seguridad por fila.';
COMMENT ON CONSTRAINT acl_una_sola_granularidad ON acl_documento IS 'Exactamente una de las tres columnas de destinatario debe estar informada.';


-- =============================================================================
-- B. Catalogo documental, versiones y relaciones
-- =============================================================================

CREATE TABLE tipo_documento (
    id              smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    codigo          text        NOT NULL UNIQUE,
    nombre          text        NOT NULL,
    descripcion     text,
    CONSTRAINT tipo_documento_codigo_formato CHECK (codigo ~ '^[a-z_]+$')
);
COMMENT ON TABLE tipo_documento IS 'Norma externa, politica interna, procedimiento, instructivo, manual de sistema, FAQ, documento historico.';


CREATE TYPE estado_documento AS ENUM ('borrador', 'vigente', 'obsoleto', 'derogado');
COMMENT ON TYPE estado_documento IS 'Estado del documento en su ciclo de vida. Participa de la recuperacion (D3), no es informativo.';


CREATE TABLE documento (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    codigo              text        NOT NULL UNIQUE,
    titulo              text        NOT NULL,
    tipo_documento_id   smallint    NOT NULL REFERENCES tipo_documento(id),
    area_id             integer     NOT NULL REFERENCES area(id),
    nivel_id            smallint    NOT NULL REFERENCES nivel_confidencialidad(id),
    estado              estado_documento NOT NULL DEFAULT 'borrador',
    -- D6: los atributos que varian entre tipos de documento (organismo emisor de
    -- una norma, ambiente de un manual de sistema) van aca y no en columnas
    -- propias, que quedarian mayormente vacias, ni en una tabla de atributos
    -- genericos, que degrada consultas e integridad.
    metadatos           jsonb       NOT NULL DEFAULT '{}'::jsonb,
    creado_por          bigint      NOT NULL REFERENCES usuario(id),
    creado_en           timestamptz NOT NULL DEFAULT now(),
    actualizado_en      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT documento_titulo_no_vacio CHECK (length(trim(titulo)) > 0),
    CONSTRAINT documento_metadatos_objeto CHECK (jsonb_typeof(metadatos) = 'object')
);
COMMENT ON TABLE documento IS 'Entidad logica del documento: su identidad, clasificacion y permisos. El contenido vive en sus versiones.';
COMMENT ON COLUMN documento.metadatos IS 'Atributos variables segun el tipo de documento (D6).';

ALTER TABLE acl_documento
    ADD CONSTRAINT acl_documento_documento_fk
    FOREIGN KEY (documento_id) REFERENCES documento(id) ON DELETE CASCADE;


CREATE TABLE documento_version (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    documento_id        bigint      NOT NULL REFERENCES documento(id) ON DELETE CASCADE,
    numero_version      text        NOT NULL,
    -- D3: la ventana de vigencia participa de la recuperacion.
    vigente_desde       date        NOT NULL,
    vigente_hasta       date,
    -- D5: el binario no se guarda. Se guarda donde esta, su hash y su texto.
    uri_original        text        NOT NULL,
    hash_sha256         char(64)    NOT NULL,
    texto               text        NOT NULL,
    creado_por          bigint      NOT NULL REFERENCES usuario(id),
    creado_en           timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT version_unica_por_documento UNIQUE (documento_id, numero_version),
    -- R4: el mismo archivo no se ingesta dos veces.
    CONSTRAINT version_hash_unico         UNIQUE (hash_sha256),
    CONSTRAINT version_hash_formato       CHECK (hash_sha256 ~ '^[0-9a-f]{64}$'),
    CONSTRAINT version_vigencia_coherente CHECK (vigente_hasta IS NULL OR vigente_hasta >= vigente_desde),
    CONSTRAINT version_texto_no_vacio     CHECK (length(trim(texto)) > 0)
);
COMMENT ON TABLE documento_version IS 'Version concreta de un documento. Es inmutable una vez creada: una correccion produce una version nueva, no una modificacion.';
COMMENT ON COLUMN documento_version.hash_sha256 IS 'Hash del archivo original. Detecta reingesta (R4) y deja constancia de integridad.';


CREATE TYPE tipo_relacion_documento AS ENUM ('deroga', 'reemplaza', 'complementa', 'referencia');

CREATE TABLE documento_relacion (
    documento_origen_id     bigint NOT NULL REFERENCES documento(id) ON DELETE CASCADE,
    documento_destino_id    bigint NOT NULL REFERENCES documento(id) ON DELETE CASCADE,
    tipo                    tipo_relacion_documento NOT NULL,
    creado_en               timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (documento_origen_id, documento_destino_id, tipo),
    CONSTRAINT relacion_no_reflexiva CHECK (documento_origen_id <> documento_destino_id)
);
COMMENT ON TABLE documento_relacion IS 'Grafo dirigido entre documentos. Se recorre en profundidad con CTE recursivo para reconstruir cadenas de derogacion.';


CREATE TABLE etiqueta (
    id              integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre          text NOT NULL UNIQUE,
    CONSTRAINT etiqueta_nombre_normalizado CHECK (nombre = lower(trim(nombre)))
);
COMMENT ON TABLE etiqueta IS 'Vocabulario transversal a las areas. Se normaliza a minusculas para evitar duplicados por mayusculas.';


CREATE TABLE documento_etiqueta (
    documento_id    bigint  NOT NULL REFERENCES documento(id) ON DELETE CASCADE,
    etiqueta_id     integer NOT NULL REFERENCES etiqueta(id)  ON DELETE CASCADE,
    PRIMARY KEY (documento_id, etiqueta_id)
);
COMMENT ON TABLE documento_etiqueta IS 'Relacion muchos a muchos entre documentos y etiquetas.';


-- =============================================================================
-- C. Contenido, fragmentos y representacion vectorial
-- =============================================================================

CREATE TABLE modelo_embedding (
    id              smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre          text        NOT NULL UNIQUE,
    dimension       integer     NOT NULL,
    metrica         text        NOT NULL DEFAULT 'coseno',
    activo          boolean     NOT NULL DEFAULT true,
    vigente_desde   date        NOT NULL DEFAULT current_date,
    CONSTRAINT modelo_dimension_valida CHECK (dimension BETWEEN 1 AND 2000),
    CONSTRAINT modelo_metrica_valida   CHECK (metrica IN ('coseno', 'l2', 'producto_interno'))
);
COMMENT ON TABLE modelo_embedding IS 'Modelo con el que se vectorizo cada fragmento. Sin este registro no hay forma de saber si dos vectores son comparables ni de planificar una revectorizacion (R5).';


CREATE TABLE chunk (
    id                      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    -- D2: el fragmento cuelga de la version, no del documento. De esa pertenencia
    -- hereda su nivel de confidencialidad y su vigencia: no lleva permisos propios.
    documento_version_id    bigint      NOT NULL REFERENCES documento_version(id) ON DELETE CASCADE,
    orden                   integer     NOT NULL,
    texto                   text        NOT NULL,
    tokens                  integer     NOT NULL,
    modelo_embedding_id     smallint    NOT NULL REFERENCES modelo_embedding(id),
    -- La dimension se fija en el tipo de la columna. Cambiar de modelo a otra
    -- dimension exige una columna nueva y una revectorizacion planificada: por eso
    -- se registra el modelo en cada fragmento.
    embedding               vector(1024),
    -- Representacion para busqueda de texto completo. Es una columna generada:
    -- no puede quedar desincronizada del texto porque no se escribe a mano.
    tsv                     tsvector GENERATED ALWAYS AS (
                                to_tsvector('public.espanol_unaccent'::regconfig, texto)
                            ) STORED,
    -- Posicion dentro del documento, para poder citar "seccion 4.2 del
    -- procedimiento" y no el documento entero.
    metadatos               jsonb       NOT NULL DEFAULT '{}'::jsonb,
    creado_en               timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT chunk_orden_unico_por_version UNIQUE (documento_version_id, orden),
    CONSTRAINT chunk_orden_positivo         CHECK (orden >= 0),
    CONSTRAINT chunk_tokens_positivo        CHECK (tokens > 0),
    CONSTRAINT chunk_texto_no_vacio         CHECK (length(trim(texto)) > 0),
    CONSTRAINT chunk_metadatos_objeto       CHECK (jsonb_typeof(metadatos) = 'object')
);
COMMENT ON TABLE chunk IS 'Unidad de recuperacion: lo que se busca, lo que entra al contexto del modelo de lenguaje y, por lo tanto, lo que puede filtrar informacion. Es la entidad de mayor criticidad y mayor volumen del modelo.';
COMMENT ON COLUMN chunk.embedding IS 'Representacion vectorial del fragmento. Nulo mientras la vectorizacion esta pendiente.';
COMMENT ON COLUMN chunk.tsv IS 'Columna generada: no puede desincronizarse del texto.';


-- =============================================================================
-- D. Uso del sistema
-- =============================================================================
-- Estas tablas crecen con el uso y no con la organizacion, se escriben mucho mas
-- de lo que se leen y casi siempre se consultan acotadas por fecha (informe 2.4).
-- Por eso se declaran particionadas por rango mensual sobre creado_en.
--
-- En una tabla particionada la clave primaria debe incluir la clave de particion.
-- De ahi que las claves sean (id, creado_en) y que las claves foraneas entre estas
-- tablas arrastren la fecha: eso ademas garantiza que padre e hijo caigan en la
-- misma particion.
-- =============================================================================

CREATE TABLE consulta (
    id                  bigint GENERATED ALWAYS AS IDENTITY,
    usuario_id          bigint      NOT NULL REFERENCES usuario(id),
    texto               text        NOT NULL,
    -- Permite agrupar consultas semanticamente equivalentes y detectar temas sin
    -- cobertura documental. Decidido en el relevamiento; su costo en tamanio queda
    -- anotado como tema del punto 14.
    embedding           vector(1024),
    modelo_embedding_id smallint    REFERENCES modelo_embedding(id),
    latencia_ms         integer,
    creado_en           timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (id, creado_en),
    CONSTRAINT consulta_texto_no_vacio  CHECK (length(trim(texto)) > 0),
    CONSTRAINT consulta_latencia_valida CHECK (latencia_ms IS NULL OR latencia_ms >= 0)
) PARTITION BY RANGE (creado_en);
COMMENT ON TABLE consulta IS 'Pregunta en lenguaje natural. Contiene posibles datos personales en el texto libre (R7): su politica de retencion se define en el punto 13.';


CREATE TABLE respuesta (
    id                  bigint GENERATED ALWAYS AS IDENTITY,
    consulta_id         bigint      NOT NULL,
    texto               text        NOT NULL,
    modelo              text        NOT NULL,
    tokens_entrada      integer,
    tokens_salida       integer,
    confianza           numeric(4,3),
    creado_en           timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (id, creado_en),
    -- Comparte la fecha con su consulta: garantiza colocacion en la misma particion.
    CONSTRAINT respuesta_consulta_fk FOREIGN KEY (consulta_id, creado_en)
        REFERENCES consulta(id, creado_en) ON DELETE CASCADE,
    CONSTRAINT respuesta_confianza_valida CHECK (confianza IS NULL OR confianza BETWEEN 0 AND 1)
) PARTITION BY RANGE (creado_en);
COMMENT ON TABLE respuesta IS 'Respuesta generada a partir de los fragmentos recuperados. El modelo de lenguaje es una caja negra: aca solo se registra cual se uso y cuanto consumio.';


CREATE TABLE respuesta_fuente (
    respuesta_id        bigint      NOT NULL,
    chunk_id            bigint      NOT NULL REFERENCES chunk(id),
    -- D4: no basta con saber que documentos se consultaron. Se registra el
    -- fragmento, su puntaje y su posicion en el ranking, que es la granularidad
    -- que permite explicar una respuesta y no solo listar fuentes.
    posicion            smallint    NOT NULL,
    puntaje             real        NOT NULL,
    creado_en           timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (respuesta_id, chunk_id, creado_en),
    CONSTRAINT respuesta_fuente_respuesta_fk FOREIGN KEY (respuesta_id, creado_en)
        REFERENCES respuesta(id, creado_en) ON DELETE CASCADE,
    CONSTRAINT fuente_posicion_positiva CHECK (posicion > 0)
) PARTITION BY RANGE (creado_en);
COMMENT ON TABLE respuesta_fuente IS 'Registra que fragmentos originaron cada respuesta (D4). Es la tabla que responde directamente al requisito de trazabilidad del caso, y una de las de mayor crecimiento.';


CREATE TABLE feedback (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    respuesta_id        bigint      NOT NULL,
    respuesta_creado_en timestamptz NOT NULL,
    usuario_id          bigint      NOT NULL REFERENCES usuario(id),
    util                boolean     NOT NULL,
    comentario          text,
    creado_en           timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT feedback_respuesta_fk FOREIGN KEY (respuesta_id, respuesta_creado_en)
        REFERENCES respuesta(id, creado_en) ON DELETE CASCADE,
    CONSTRAINT feedback_unico_por_usuario UNIQUE (respuesta_id, respuesta_creado_en, usuario_id)
);
COMMENT ON TABLE feedback IS 'Valoracion del usuario sobre una respuesta. El comentario libre es dato no estructurado y alimenta la deteccion de temas sin cobertura.';


-- =============================================================================
-- E. Auditoria
-- =============================================================================
-- Ambas son de solo insercion. Un registro de auditoria modificable no sirve como
-- registro de auditoria; que no se pueda actualizar ni borrar se garantiza con
-- permisos y politicas en 05_rls.sql, no solo por convencion.
-- =============================================================================

CREATE TABLE log_acceso (
    id                  bigint GENERATED ALWAYS AS IDENTITY,
    usuario_id          bigint      NOT NULL REFERENCES usuario(id),
    documento_id        bigint      REFERENCES documento(id),
    chunk_id            bigint      REFERENCES chunk(id),
    accion              text        NOT NULL,
    contexto            jsonb       NOT NULL DEFAULT '{}'::jsonb,
    creado_en           timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (id, creado_en),
    CONSTRAINT log_accion_valida    CHECK (accion IN ('consulta', 'lectura', 'descarga', 'recuperacion')),
    CONSTRAINT log_objeto_informado CHECK (num_nonnulls(documento_id, chunk_id) >= 1)
) PARTITION BY RANGE (creado_en);
COMMENT ON TABLE log_acceso IS 'Quien accedio a que documento o fragmento, cuando y en que contexto. Responde "quien accedio a este documento confidencial en los ultimos noventa dias".';


CREATE TABLE auditoria (
    id                  bigint GENERATED ALWAYS AS IDENTITY,
    usuario_id          bigint      NOT NULL REFERENCES usuario(id),
    entidad             text        NOT NULL,
    entidad_id          bigint      NOT NULL,
    operacion           text        NOT NULL,
    -- Estado anterior y posterior del registro afectado. Se guardan como documento
    -- estructurado porque la forma cambia segun la entidad auditada.
    datos_antes         jsonb,
    datos_despues       jsonb,
    creado_en           timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (id, creado_en),
    CONSTRAINT auditoria_operacion_valida CHECK (operacion IN ('alta', 'modificacion', 'baja')),
    CONSTRAINT auditoria_algun_dato       CHECK (num_nonnulls(datos_antes, datos_despues) >= 1)
) PARTITION BY RANGE (creado_en);
COMMENT ON TABLE auditoria IS 'Cambios sobre datos sensibles: alta y baja de permisos, cambios de estado documental, cambios de clasificacion. Es de maxima criticidad y de solo insercion.';
