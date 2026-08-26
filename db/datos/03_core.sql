-- =============================================================================
-- 03 - raw -> core
-- =============================================================================
-- Resuelve las claves subrogadas y aplica las conversiones de tipo. Es el unico
-- lugar del proyecto donde las claves naturales del generador se traducen a los
-- identificadores que asigno el motor.
--
-- El orden de las sentencias es el de las dependencias: usuario antes que
-- documento (que lo referencia en creado_por), documento antes que sus
-- versiones, versiones antes que los fragmentos, y la cadena
-- consulta -> respuesta -> respuesta_fuente al final.
--
-- Sobre las tablas particionadas: consulta, respuesta y respuesta_fuente tienen
-- clave primaria compuesta (id, creado_en) y sus claves foraneas arrastran la
-- fecha, para garantizar que padre e hijo caigan en la misma particion. Por eso
-- las tres comparten `creado_en`, y por eso la forma de reencontrar una consulta
-- ya insertada es su `creado_en`, que el generador emite unico.
-- =============================================================================

SET search_path = core, public;

BEGIN;

-- -----------------------------------------------------------------------------
-- Usuarios y roles
-- -----------------------------------------------------------------------------

INSERT INTO usuario (identidad_ext, nombre, email, area_id, nivel_habilitacion_id,
                     activo, baja_en)
SELECT r.identidad_ext, r.nombre, r.email, a.id, n.id,
       r.activo::boolean,
       nullif(r.baja_en, '')::timestamptz
FROM raw.usuario r
JOIN area a                    ON a.nombre = r.area
JOIN nivel_confidencialidad n  ON n.nombre = r.nivel_habilitacion;

INSERT INTO usuario_rol (usuario_id, rol_id)
SELECT u.id, ro.id
FROM raw.usuario_rol r
JOIN usuario u ON u.email  = r.usuario
JOIN rol ro    ON ro.nombre = r.rol;


-- -----------------------------------------------------------------------------
-- Catalogo documental
-- -----------------------------------------------------------------------------

INSERT INTO etiqueta (nombre)
SELECT DISTINCT nombre FROM raw.etiqueta;

INSERT INTO documento (codigo, titulo, tipo_documento_id, area_id, nivel_id,
                       estado, metadatos, creado_por)
SELECT r.codigo, r.titulo, t.id, a.id, n.id,
       r.estado::estado_documento,
       r.metadatos::jsonb,
       u.id
FROM raw.documento r
JOIN tipo_documento t          ON t.codigo = r.tipo
JOIN area a                    ON a.nombre = r.area
JOIN nivel_confidencialidad n  ON n.nombre = r.nivel
JOIN usuario u                 ON u.email  = r.creado_por;

INSERT INTO documento_version (documento_id, numero_version, vigente_desde,
                               vigente_hasta, uri_original, hash_sha256, texto,
                               creado_por)
SELECT d.id, r.numero_version, r.vigente_desde::date,
       nullif(r.vigente_hasta, '')::date,
       r.uri_original, r.hash_sha256, r.texto, u.id
FROM raw.documento_version r
JOIN documento d ON d.codigo = r.documento
JOIN usuario u   ON u.email  = r.creado_por;

INSERT INTO documento_relacion (documento_origen_id, documento_destino_id, tipo)
SELECT o.id, dst.id, r.tipo::tipo_relacion_documento
FROM raw.documento_relacion r
JOIN documento o   ON o.codigo   = r.origen
JOIN documento dst ON dst.codigo = r.destino;

INSERT INTO documento_etiqueta (documento_id, etiqueta_id)
SELECT DISTINCT d.id, e.id
FROM raw.documento_etiqueta r
JOIN documento d ON d.codigo = r.documento
JOIN etiqueta e  ON e.nombre = r.etiqueta;


-- -----------------------------------------------------------------------------
-- Otorgamientos de acceso
-- -----------------------------------------------------------------------------
-- Las tres granularidades son excluyentes entre si (restriccion
-- acl_una_sola_granularidad): la fila lleva area_id, rol_id o usuario_id, y las
-- otras dos en nulo. El CASE materializa esa exclusion en la carga.
-- -----------------------------------------------------------------------------

INSERT INTO acl_documento (documento_id, area_id, rol_id, usuario_id,
                           vigente_desde, vigente_hasta, otorgado_por)
SELECT d.id,
       CASE WHEN r.granularidad = 'area'    THEN a.id  END,
       CASE WHEN r.granularidad = 'rol'     THEN ro.id END,
       CASE WHEN r.granularidad = 'usuario' THEN ud.id END,
       r.vigente_desde::timestamptz,
       nullif(r.vigente_hasta, '')::timestamptz,
       uo.id
FROM raw.acl_documento r
JOIN documento d  ON d.codigo = r.documento
LEFT JOIN area a  ON r.granularidad = 'area'    AND a.nombre  = r.destinatario
LEFT JOIN rol ro  ON r.granularidad = 'rol'     AND ro.nombre = r.destinatario
LEFT JOIN usuario ud ON r.granularidad = 'usuario' AND ud.email = r.destinatario
JOIN usuario uo   ON uo.email = r.otorgado_por;


-- -----------------------------------------------------------------------------
-- Fragmentos
-- -----------------------------------------------------------------------------
-- `tsv` no se inserta: es una columna generada a partir de `texto`, justamente
-- para que no pueda desincronizarse de el.
-- -----------------------------------------------------------------------------

INSERT INTO chunk (documento_version_id, orden, texto, tokens,
                   modelo_embedding_id, embedding, metadatos)
SELECT v.id, r.orden::integer, r.texto, r.tokens::integer, m.id,
       r.embedding::vector(1024),
       r.metadatos::jsonb
FROM raw.chunk r
JOIN documento d          ON d.codigo = r.documento
JOIN documento_version v  ON v.documento_id = d.id AND v.numero_version = r.numero_version
JOIN modelo_embedding m   ON m.nombre = r.modelo;


-- -----------------------------------------------------------------------------
-- Uso del sistema
-- -----------------------------------------------------------------------------

INSERT INTO consulta (usuario_id, texto, embedding, modelo_embedding_id,
                      latencia_ms, creado_en)
SELECT u.id, r.texto, r.embedding::vector(1024), m.id,
       r.latencia_ms::integer, r.creado_en::timestamptz
FROM raw.consulta r
JOIN usuario u          ON u.email  = r.usuario
JOIN modelo_embedding m ON m.nombre = r.modelo;

-- Mapa clave natural -> (id, creado_en) de la consulta. `creado_en` es unico por
-- consulta (lo garantiza el generador) y es la unica via para reencontrarla.
CREATE TEMP TABLE mapa_consulta ON COMMIT DROP AS
SELECT rc.clave, c.id, c.creado_en
FROM raw.consulta rc
JOIN consulta c ON c.creado_en = rc.creado_en::timestamptz;

INSERT INTO respuesta (consulta_id, texto, modelo, tokens_entrada, tokens_salida,
                       confianza, creado_en)
SELECT mc.id, r.texto, r.modelo, r.tokens_entrada::integer,
       r.tokens_salida::integer, r.confianza::numeric(4,3), mc.creado_en
FROM raw.respuesta r
JOIN mapa_consulta mc ON mc.clave = r.consulta;

CREATE TEMP TABLE mapa_respuesta ON COMMIT DROP AS
SELECT mc.clave, rp.id, rp.creado_en
FROM mapa_consulta mc
JOIN respuesta rp ON rp.consulta_id = mc.id AND rp.creado_en = mc.creado_en;

INSERT INTO respuesta_fuente (respuesta_id, chunk_id, posicion, puntaje, creado_en)
SELECT mr.id, ch.id, r.posicion::smallint, r.puntaje::real, mr.creado_en
FROM raw.respuesta_fuente r
JOIN mapa_respuesta mr    ON mr.clave = r.consulta
JOIN documento d          ON d.codigo = r.documento
JOIN documento_version v  ON v.documento_id = d.id AND v.numero_version = r.numero_version
JOIN chunk ch             ON ch.documento_version_id = v.id AND ch.orden = r.orden_chunk::integer;

INSERT INTO feedback (respuesta_id, respuesta_creado_en, usuario_id, util,
                      comentario, creado_en)
SELECT mr.id, mr.creado_en, u.id, r.util::boolean,
       nullif(r.comentario, ''), r.creado_en::timestamptz
FROM raw.feedback r
JOIN mapa_respuesta mr ON mr.clave = r.consulta
JOIN usuario u         ON u.email = r.usuario;


-- -----------------------------------------------------------------------------
-- Auditoria
-- -----------------------------------------------------------------------------

INSERT INTO log_acceso (usuario_id, documento_id, chunk_id, accion, contexto, creado_en)
SELECT u.id, d.id, ch.id, r.accion, r.contexto::jsonb, r.creado_en::timestamptz
FROM raw.log_acceso r
JOIN usuario u            ON u.email  = r.usuario
JOIN documento d          ON d.codigo = r.documento
JOIN documento_version v  ON v.documento_id = d.id AND v.numero_version = r.numero_version
JOIN chunk ch             ON ch.documento_version_id = v.id AND ch.orden = r.orden_chunk::integer;

-- entidad_id es el id real de la fila auditada; la referencia natural del CSV se
-- resuelve contra documento o acl_documento segun la entidad.
INSERT INTO auditoria (usuario_id, entidad, entidad_id, operacion, datos_antes,
                       datos_despues, creado_en)
SELECT u.id, r.entidad,
       CASE r.entidad
           WHEN 'documento' THEN (SELECT d.id FROM documento d WHERE d.codigo = r.referencia)
           WHEN 'acl_documento' THEN (
               SELECT min(a.id) FROM acl_documento a
               JOIN documento d ON d.id = a.documento_id
               LEFT JOIN area ar   ON ar.id = a.area_id
               LEFT JOIN rol ro    ON ro.id = a.rol_id
               LEFT JOIN usuario ud ON ud.id = a.usuario_id
               WHERE d.codigo = split_part(r.referencia, ':', 1)
                 AND coalesce(ar.nombre, ro.nombre, ud.email) = split_part(r.referencia, ':', 3))
       END,
       r.operacion,
       nullif(r.datos_antes, '')::jsonb,
       nullif(r.datos_despues, '')::jsonb,
       r.creado_en::timestamptz
FROM raw.auditoria r
JOIN usuario u ON u.email = r.usuario;

COMMIT;

\echo 'Carga en core completa.'
