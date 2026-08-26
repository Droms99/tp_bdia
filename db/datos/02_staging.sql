-- =============================================================================
-- 02 - Aterrizaje de los CSV en el esquema raw
-- =============================================================================
-- Los CSV que emite `etl/generar_dataset.py` usan claves naturales
-- (documento.codigo, usuario.email, etiqueta.nombre) y no identificadores: las
-- claves subrogadas las asigna el motor, y quien las resuelve es 03_core.sql.
--
-- Ese paso intermedio es la razon de ser del esquema `raw` (informe, punto 12).
-- Cargar directo a `core` obligaria a que el generador conociera los ids que el
-- motor todavia no asigno, o a insertar fila por fila resolviendo cada clave
-- foranea con una subconsulta. Con una capa de aterrizaje, la carga es un COPY
-- masivo y la resolucion de claves es una sentencia por tabla.
--
-- Todas las columnas son `text`: en la capa de aterrizaje no se valida ni se
-- convierte. Si un dato viene mal, tiene que fallar en el paso a `core`, donde
-- estan las restricciones, y no en la lectura del archivo, donde el error no
-- dice nada util.
--
-- RUTA DE LOS ARCHIVOS: '/data/generado' es el punto de montaje de ./data dentro
-- del contenedor (docker-compose.yml). Se usa COPY del lado del servidor porque
-- los scripts se ejecutan con `make psql`, es decir, dentro del contenedor. Para
-- correrlos desde un psql instalado en la maquina, reemplazar `COPY` por `\copy`
-- y la ruta por la del repositorio.
-- =============================================================================

BEGIN;

DROP TABLE IF EXISTS raw.usuario, raw.usuario_rol, raw.etiqueta, raw.documento,
    raw.documento_version, raw.documento_relacion, raw.documento_etiqueta,
    raw.acl_documento, raw.chunk, raw.consulta, raw.respuesta,
    raw.respuesta_fuente, raw.feedback, raw.log_acceso, raw.auditoria CASCADE;

CREATE TABLE raw.usuario (
    identidad_ext text, nombre text, email text, area text,
    nivel_habilitacion text, activo text, baja_en text);

CREATE TABLE raw.usuario_rol (usuario text, rol text);

CREATE TABLE raw.etiqueta (nombre text);

CREATE TABLE raw.documento (
    codigo text, titulo text, tipo text, area text, nivel text, estado text,
    metadatos text, creado_por text);

CREATE TABLE raw.documento_version (
    documento text, numero_version text, vigente_desde text, vigente_hasta text,
    uri_original text, hash_sha256 text, texto text, creado_por text);

CREATE TABLE raw.documento_relacion (origen text, destino text, tipo text);

CREATE TABLE raw.documento_etiqueta (documento text, etiqueta text);

CREATE TABLE raw.acl_documento (
    documento text, granularidad text, destinatario text,
    vigente_desde text, vigente_hasta text, otorgado_por text);

CREATE TABLE raw.chunk (
    documento text, numero_version text, orden text, texto text, tokens text,
    modelo text, embedding text, metadatos text);

CREATE TABLE raw.consulta (
    clave text, usuario text, texto text, embedding text, modelo text,
    latencia_ms text, creado_en text);

CREATE TABLE raw.respuesta (
    consulta text, texto text, modelo text, tokens_entrada text,
    tokens_salida text, confianza text, creado_en text);

CREATE TABLE raw.respuesta_fuente (
    consulta text, documento text, numero_version text, orden_chunk text,
    posicion text, puntaje text, creado_en text);

CREATE TABLE raw.feedback (
    consulta text, usuario text, util text, comentario text, creado_en text);

CREATE TABLE raw.log_acceso (
    usuario text, documento text, numero_version text, orden_chunk text,
    accion text, contexto text, creado_en text);

CREATE TABLE raw.auditoria (
    usuario text, entidad text, referencia text, operacion text,
    datos_antes text, datos_despues text, creado_en text);

COMMENT ON SCHEMA raw IS
    'Capa de aterrizaje: los datos tal como llegan, con claves naturales y sin convertir. La normalizacion y la resolucion de claves ocurren al pasar a core (03_core.sql).';


-- -----------------------------------------------------------------------------
-- Carga
-- -----------------------------------------------------------------------------

COPY raw.usuario            FROM '/data/generado/usuario.csv'            CSV HEADER;
COPY raw.usuario_rol        FROM '/data/generado/usuario_rol.csv'        CSV HEADER;
COPY raw.etiqueta           FROM '/data/generado/etiqueta.csv'           CSV HEADER;
COPY raw.documento          FROM '/data/generado/documento.csv'          CSV HEADER;
COPY raw.documento_version  FROM '/data/generado/documento_version.csv'  CSV HEADER;
COPY raw.documento_relacion FROM '/data/generado/documento_relacion.csv' CSV HEADER;
COPY raw.documento_etiqueta FROM '/data/generado/documento_etiqueta.csv' CSV HEADER;
COPY raw.acl_documento      FROM '/data/generado/acl_documento.csv'      CSV HEADER;
COPY raw.chunk              FROM '/data/generado/chunk.csv'              CSV HEADER;
COPY raw.consulta           FROM '/data/generado/consulta.csv'           CSV HEADER;
COPY raw.respuesta          FROM '/data/generado/respuesta.csv'          CSV HEADER;
COPY raw.respuesta_fuente   FROM '/data/generado/respuesta_fuente.csv'   CSV HEADER;
COPY raw.feedback           FROM '/data/generado/feedback.csv'           CSV HEADER;
COPY raw.log_acceso         FROM '/data/generado/log_acceso.csv'         CSV HEADER;
COPY raw.auditoria          FROM '/data/generado/auditoria.csv'          CSV HEADER;

COMMIT;

\echo 'Aterrizaje en raw completo:'
SELECT 'usuario' AS tabla, count(*) FROM raw.usuario
UNION ALL SELECT 'documento',          count(*) FROM raw.documento
UNION ALL SELECT 'documento_version',  count(*) FROM raw.documento_version
UNION ALL SELECT 'chunk',              count(*) FROM raw.chunk
UNION ALL SELECT 'acl_documento',      count(*) FROM raw.acl_documento
UNION ALL SELECT 'consulta',           count(*) FROM raw.consulta
UNION ALL SELECT 'respuesta',          count(*) FROM raw.respuesta
UNION ALL SELECT 'respuesta_fuente',   count(*) FROM raw.respuesta_fuente
UNION ALL SELECT 'log_acceso',         count(*) FROM raw.log_acceso
UNION ALL SELECT 'auditoria',          count(*) FROM raw.auditoria
ORDER BY 1;
