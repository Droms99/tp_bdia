-- =============================================================================
-- Consulta 3 - Trazabilidad: de que salio exactamente esta respuesta
-- =============================================================================
-- QUE PREGUNTA RESPONDE
--   "El sistema le contesto esto a esta persona en esta fecha. ¿Con que
--    fragmentos lo armo, de que documento, de que version de ese documento, y
--    esa version seguia vigente en ese momento?"
--
-- POR QUE ES UTIL
--   Es el requisito explicito del caso: registrar que documentos se usaron para
--   construir cada respuesta. Pero el requisito completo es mas exigente que
--   "listar las fuentes", y por eso `respuesta_fuente` guarda tambien la
--   posicion en el ranking y el puntaje: con eso se puede explicar por que el
--   modelo dijo lo que dijo, y no solo que documentos tenia a mano.
--
--   La pieza que lo hace posible es la decision D2: los fragmentos cuelgan de la
--   VERSION, no del documento. Si colgaran del documento, publicar una version
--   nueva obligaria a decidir que hacer con los fragmentos viejos, y se perderia
--   la posibilidad de reconstruir con que texto exacto se respondio una consulta
--   de hace seis meses. Aca la version citada se conserva aunque el documento
--   haya cambiado despues.
--
--   Se ejecuta como tp_auditor, no como tp_lector: el rol de la aplicacion no
--   tiene SELECT sobre consulta ni respuesta (05_rls.sql). Auditar las respuestas
--   de otro es una funcion distinta de consultar.
--
-- COMO CORRERLA
--   make psql   y despues   \i /scripts/consultas/03_trazabilidad.sql
-- =============================================================================

\pset pager off

BEGIN;
SET LOCAL ROLE tp_auditor;

\echo ''
\echo '=== A) La misma pregunta, tres personas, tres conjuntos de fuentes ==='
-- La consulta 1 mostro que el motor devuelve filas distintas segun quien
-- pregunta. Esto es la contraparte registrada de aquello: la misma pregunta
-- quedo respondida con fuentes distintas segun el permiso de cada uno, y eso
-- esta escrito en la base, no hay que deducirlo.

-- Una consulta por persona: la mas reciente de cada una, para que las tres
-- caigan sobre el mismo corpus vigente y la unica variable sea el permiso.
WITH elegidas AS (
    SELECT DISTINCT ON (c.usuario_id) c.id, c.creado_en, c.usuario_id
    FROM core.consulta c
    JOIN core.usuario u ON u.id = c.usuario_id
    WHERE c.texto = 'que paso con la investigacion por accesos indebidos al nucleo bancario'
      AND u.email IN ('mocampo@banco-ejemplo.com.ar',   -- Auditoria, restringido
                      'hotero@banco-ejemplo.com.ar',    -- Auditoria, confidencial
                      'lgimenez@banco-ejemplo.com.ar')  -- Operaciones, interno
    ORDER BY c.usuario_id, c.creado_en DESC
)
SELECT u.nombre                       AS pregunto,
       nu.nombre                      AS habilitacion,
       e.creado_en::date              AS fecha,
       rf.posicion                    AS pos,
       d.codigo                       AS documento,
       v.numero_version               AS version,
       ch.metadatos ->> 'seccion'     AS seccion,
       round(rf.puntaje::numeric, 4)  AS puntaje,
       n.nombre                       AS nivel
FROM elegidas e
JOIN core.usuario u              ON u.id = e.usuario_id
JOIN core.nivel_confidencialidad nu ON nu.id = u.nivel_habilitacion_id
JOIN core.respuesta rp           ON rp.consulta_id = e.id  AND rp.creado_en = e.creado_en
JOIN core.respuesta_fuente rf    ON rf.respuesta_id = rp.id AND rf.creado_en = rp.creado_en
JOIN core.chunk ch               ON ch.id = rf.chunk_id
JOIN core.documento_version v    ON v.id = ch.documento_version_id
JOIN core.documento d            ON d.id = v.documento_id
JOIN core.nivel_confidencialidad n ON n.id = d.nivel_id
ORDER BY nu.orden DESC, rf.posicion;

\echo ''
\echo '=== B) El texto que efectivamente entro al contexto del modelo ==='

SELECT rf.posicion AS pos,
       d.codigo || ' v' || v.numero_version AS fuente,
       left(ch.texto, 180) || '...'         AS fragmento
FROM core.consulta c
JOIN core.respuesta rp        ON rp.consulta_id = c.id  AND rp.creado_en = c.creado_en
JOIN core.respuesta_fuente rf ON rf.respuesta_id = rp.id AND rf.creado_en = rp.creado_en
JOIN core.chunk ch            ON ch.id = rf.chunk_id
JOIN core.documento_version v ON v.id = ch.documento_version_id
JOIN core.documento d         ON d.id = v.documento_id
-- Anclada a UNA consulta concreta: la primera que registro ese texto. Sin el
-- anclaje, el LIMIT mezcla la posicion 1 de varias consultas distintas.
WHERE (c.id, c.creado_en) = (
        SELECT c2.id, c2.creado_en FROM core.consulta c2
        WHERE c2.texto = 'que paso con la investigacion por accesos indebidos al nucleo bancario'
        ORDER BY c2.creado_en LIMIT 1)
ORDER BY rf.posicion
LIMIT 3;

\echo ''
\echo '=== C) El caso que justifica D2: un documento con tres versiones ==='
-- DOC-CMP-005 tiene tres versiones sucesivas. Las respuestas citan la version
-- que estaba vigente cuando se respondio, no "el documento". Si los fragmentos
-- colgaran del documento, esta distincion no existiria.

SELECT d.codigo,
       v.numero_version                                    AS version,
       v.vigente_desde,
       coalesce(v.vigente_hasta::text, 'vigente')          AS vigente_hasta,
       count(DISTINCT ch.id)                               AS fragmentos,
       count(rf.chunk_id)                                  AS veces_citada
FROM core.documento d
JOIN core.documento_version v ON v.documento_id = d.id
LEFT JOIN core.chunk ch            ON ch.documento_version_id = v.id
LEFT JOIN core.respuesta_fuente rf ON rf.chunk_id = ch.id
WHERE d.codigo = 'DOC-CMP-005'
GROUP BY d.codigo, v.numero_version, v.vigente_desde, v.vigente_hasta
ORDER BY v.vigente_desde;

\echo ''
\echo '=== D) Quien accedio a un documento restringido, y por que via ==='
-- El acceso por recuperacion no lo vive nadie como una lectura: el usuario
-- pregunto algo y el sistema uso el documento. Sin registrarlo, ese acceso no
-- existiria en ninguna auditoria.

SELECT u.nombre,
       l.accion,
       count(*)          AS accesos,
       min(l.creado_en)::date AS primero,
       max(l.creado_en)::date AS ultimo
FROM core.log_acceso l
JOIN core.usuario u   ON u.id = l.usuario_id
JOIN core.documento d ON d.id = l.documento_id
WHERE d.codigo = 'DOC-AUD-003'
GROUP BY u.nombre, l.accion
ORDER BY accesos DESC;

COMMIT;
