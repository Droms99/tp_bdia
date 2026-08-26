-- =============================================================================
-- Consulta 1 - El mismo pedido, dos usuarios, dos resultados
-- =============================================================================
-- QUE PREGUNTA RESPONDE
--   "¿Que paso con la investigacion por accesos indebidos al nucleo bancario?"
--   Formulada por dos personas distintas.
--
-- POR QUE ES UTIL
--   Es la consulta que justifica todo el diseño. Una busqueda por similitud es
--   ciega al permiso: el fragmento mas relevante para esta pregunta es el
--   informe de investigacion DOC-AUD-003, clasificado como restringido. Si el
--   filtro de permisos viviera en la aplicacion, bastaria una consulta mal
--   escrita —o una ruta nueva que se olvide el WHERE— para que ese fragmento
--   entre al contexto del modelo de lenguaje. Y a diferencia de una consulta
--   comun, aca el modelo *redacta* con ese contenido: la respuesta filtra lo que
--   el documento decia aunque el documento nunca se muestre.
--
--   Aca el filtro no lo escribe quien consulta. La consulta que se ejecuta es
--   IDENTICA para los dos usuarios; lo unico que cambia es el `app.usuario_id`
--   que la aplicacion declara al abrir la transaccion. El motor devuelve filas
--   distintas porque la politica de seguridad de fila se aplica sola.
--
-- COMO CORRERLA
--   make psql   y despues   \i /scripts/consultas/01_control_de_acceso.sql
-- =============================================================================

\pset pager off
\set QUIET on

-- El vector de la pregunta lo calcula la aplicacion, no la base: aca se toma el
-- de una consulta ya registrada, que es exactamente el mismo dato que la
-- aplicacion pasaria como parametro. Se captura ANTES de asumir el rol de la
-- aplicacion, porque tp_lector no tiene SELECT sobre `consulta` (05_rls.sql):
-- no hay requisito que justifique que un usuario lea las preguntas de otro.
SELECT embedding::text AS vec,
       texto           AS preg
FROM core.consulta
WHERE texto = 'que paso con la investigacion por accesos indebidos al nucleo bancario'
ORDER BY creado_en
LIMIT 1
\gset

SELECT id AS uid_laura FROM core.usuario WHERE email = 'lgimenez@banco-ejemplo.com.ar' \gset
SELECT id AS uid_marta FROM core.usuario WHERE email = 'mocampo@banco-ejemplo.com.ar' \gset
\set QUIET off

\echo ''
\echo '########################################################################'
\echo '# Pregunta:' :'preg'
\echo '########################################################################'


-- -----------------------------------------------------------------------------
-- Usuario A: Laura Gimenez - analista de Operaciones, habilitacion "interno"
-- -----------------------------------------------------------------------------
\echo ''
\echo '=== A) Laura Gimenez (Operaciones, habilitacion interno) ==='

BEGIN;
SET LOCAL ROLE tp_lector;
SET LOCAL app.usuario_id = :uid_laura;

SELECT d.codigo,
       d.titulo,
       n.nombre                                   AS nivel,
       a.nombre                                   AS area,
       ch.metadatos ->> 'seccion'                 AS seccion,
       round((1 - (ch.embedding <=> :'vec'::vector))::numeric, 4) AS similitud
FROM core.chunk ch
JOIN core.documento_version v ON v.id = ch.documento_version_id
JOIN core.documento d         ON d.id = v.documento_id
JOIN core.nivel_confidencialidad n ON n.id = d.nivel_id
JOIN core.area a              ON a.id = d.area_id
-- Vigencia (D3): eje independiente del permiso. Lo aplica la consulta, no la
-- politica, para que el auditor pueda consultar el historico derogado.
WHERE d.estado = 'vigente'
  AND v.vigente_desde <= current_date
  AND (v.vigente_hasta IS NULL OR v.vigente_hasta >= current_date)
ORDER BY ch.embedding <=> :'vec'::vector
LIMIT 5;

COMMIT;


-- -----------------------------------------------------------------------------
-- Usuario B: Marta Ocampo - auditora interna, habilitacion "restringido"
-- -----------------------------------------------------------------------------
-- Misma consulta. Literalmente la misma: cambia el usuario declarado.
-- -----------------------------------------------------------------------------
\echo ''
\echo '=== B) Marta Ocampo (Auditoria Interna, habilitacion restringido) ==='

BEGIN;
SET LOCAL ROLE tp_lector;
SET LOCAL app.usuario_id = :uid_marta;

SELECT d.codigo,
       d.titulo,
       n.nombre                                   AS nivel,
       a.nombre                                   AS area,
       ch.metadatos ->> 'seccion'                 AS seccion,
       round((1 - (ch.embedding <=> :'vec'::vector))::numeric, 4) AS similitud
FROM core.chunk ch
JOIN core.documento_version v ON v.id = ch.documento_version_id
JOIN core.documento d         ON d.id = v.documento_id
JOIN core.nivel_confidencialidad n ON n.id = d.nivel_id
JOIN core.area a              ON a.id = d.area_id
WHERE d.estado = 'vigente'
  AND v.vigente_desde <= current_date
  AND (v.vigente_hasta IS NULL OR v.vigente_hasta >= current_date)
ORDER BY ch.embedding <=> :'vec'::vector
LIMIT 5;

COMMIT;


-- -----------------------------------------------------------------------------
-- Cuanto ve cada uno del corpus completo
-- -----------------------------------------------------------------------------
\echo ''
\echo '=== C) Alcance total de cada usuario sobre el corpus ==='

BEGIN;
SET LOCAL ROLE tp_lector;
SET LOCAL app.usuario_id = :uid_laura;
SELECT 'Laura Gimenez  (Operaciones, interno)' AS usuario,
       count(*) AS documentos_visibles,
       (SELECT count(*) FROM core.chunk) AS fragmentos_visibles
FROM core.documento;
COMMIT;

BEGIN;
SET LOCAL ROLE tp_lector;
SET LOCAL app.usuario_id = :uid_marta;
SELECT 'Marta Ocampo   (Auditoria, restringido)' AS usuario,
       count(*) AS documentos_visibles,
       (SELECT count(*) FROM core.chunk) AS fragmentos_visibles
FROM core.documento;
COMMIT;

-- Sin RLS de por medio, para tener el total contra el que comparar.
SELECT 'TOTAL en la base (sin politica aplicada)' AS usuario,
       count(*) AS documentos_visibles,
       (SELECT count(*) FROM core.chunk) AS fragmentos_visibles
FROM core.documento;


-- -----------------------------------------------------------------------------
-- Y la vuelta de tuerca: tp_lector no puede mirar la ACL para deducir que existe
-- -----------------------------------------------------------------------------
\echo ''
\echo '=== D) tp_lector no puede leer la tabla de otorgamientos ==='
BEGIN;
SET LOCAL ROLE tp_lector;
\set ON_ERROR_STOP off
SELECT count(*) FROM core.acl_documento;
\set ON_ERROR_STOP on
ROLLBACK;
