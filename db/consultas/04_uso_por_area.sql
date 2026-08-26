-- =============================================================================
-- Consulta 4 - Indicadores de uso por area y por tipo de documento
-- =============================================================================
-- QUE PREGUNTA RESPONDE
--   "¿Quien usa el sistema, para preguntar sobre que, y donde esta el
--    conocimiento que la organizacion efectivamente consulta?"
--
-- POR QUE ES UTIL
--   Tiene dos destinatarios distintos.
--
--   Al curador documental le dice donde poner el esfuerzo: un documento muy
--   citado merece revision cuidadosa antes de publicarle una version nueva, y
--   uno que nadie cito en seis meses probablemente no haga falta mantenerlo con
--   la misma prolijidad. Sin este dato, la prioridad de curaduria se decide por
--   intuicion.
--
--   Al responsable de la solucion le dice si el sistema sirve. La proporcion de
--   respuestas marcadas como no utiles, abierta por area, distingue dos
--   problemas que se confunden: "el sistema recupera mal" y "esa area no tiene
--   su documentacion cargada".
--
--   Se ejecuta como tp_auditor. Es la lectura agregada del uso del sistema, no
--   la operacion del RAG: tp_lector no tiene SELECT sobre consulta ni respuesta.
--
-- COMO CORRERLA
--   make psql   y despues   \i /scripts/consultas/04_uso_por_area.sql
-- =============================================================================

\pset pager off

BEGIN;
SET LOCAL ROLE tp_auditor;

\echo ''
\echo '=== A) Uso del sistema por area que pregunta ==='

SELECT a.nombre                                                    AS area,
       count(DISTINCT c.usuario_id)                                AS personas,
       count(*)                                                    AS consultas,
       count(rp.id)                                                AS respondidas,
       count(*) - count(rp.id)                                     AS sin_cobertura,
       round(100.0 * (count(*) - count(rp.id)) / count(*), 1)      AS pct_sin_cobertura,
       round(avg(c.latencia_ms))                                   AS latencia_ms_prom
FROM core.consulta c
JOIN core.usuario u ON u.id = c.usuario_id
JOIN core.area a    ON a.id = u.area_id
LEFT JOIN core.respuesta rp ON rp.consulta_id = c.id AND rp.creado_en = c.creado_en
GROUP BY a.nombre
ORDER BY consultas DESC;

\echo ''
\echo '=== B) Donde esta el conocimiento que se consulta: documentos mas citados ==='

SELECT d.codigo,
       left(d.titulo, 52)                       AS titulo,
       a.nombre                                 AS area_propietaria,
       t.codigo                                 AS tipo,
       n.nombre                                 AS nivel,
       count(*)                                 AS veces_citado,
       count(DISTINCT c.usuario_id)             AS personas_distintas,
       round(avg(rf.posicion), 2)               AS posicion_media
FROM core.respuesta_fuente rf
JOIN core.respuesta rp        ON rp.id = rf.respuesta_id AND rp.creado_en = rf.creado_en
JOIN core.consulta c          ON c.id = rp.consulta_id   AND c.creado_en  = rp.creado_en
JOIN core.chunk ch            ON ch.id = rf.chunk_id
JOIN core.documento_version v ON v.id = ch.documento_version_id
JOIN core.documento d         ON d.id = v.documento_id
JOIN core.area a              ON a.id = d.area_id
JOIN core.tipo_documento t    ON t.id = d.tipo_documento_id
JOIN core.nivel_confidencialidad n ON n.id = d.nivel_id
GROUP BY d.codigo, d.titulo, a.nombre, t.codigo, n.nombre
ORDER BY veces_citado DESC
LIMIT 12;

\echo ''
\echo '=== C) Que tipo de documentacion responde las preguntas ==='

SELECT t.nombre                                              AS tipo,
       count(DISTINCT d.id)                                  AS documentos,
       count(rf.chunk_id)                                    AS citas,
       round(100.0 * count(rf.chunk_id)
             / nullif(sum(count(rf.chunk_id)) OVER (), 0), 1) AS pct_citas
FROM core.tipo_documento t
LEFT JOIN core.documento d         ON d.tipo_documento_id = t.id
LEFT JOIN core.documento_version v ON v.documento_id = d.id
LEFT JOIN core.chunk ch            ON ch.documento_version_id = v.id
LEFT JOIN core.respuesta_fuente rf ON rf.chunk_id = ch.id
GROUP BY t.nombre
ORDER BY citas DESC;

\echo ''
\echo '=== D) Documentacion cargada que nadie consulto nunca ==='
-- El complemento de (B). Un documento vigente que nunca fue fuente de una
-- respuesta o no le interesa a nadie, o esta redactado de un modo que la
-- recuperacion no alcanza. Las dos conclusiones son accionables y distintas.

SELECT d.codigo,
       left(d.titulo, 55) AS titulo,
       a.nombre           AS area,
       n.nombre           AS nivel,
       (SELECT count(*) FROM core.chunk c2
        JOIN core.documento_version v2 ON v2.id = c2.documento_version_id
        WHERE v2.documento_id = d.id) AS fragmentos
FROM core.documento d
JOIN core.area a                   ON a.id = d.area_id
JOIN core.nivel_confidencialidad n ON n.id = d.nivel_id
WHERE d.estado = 'vigente'
  -- Ningun fragmento de ninguna de sus versiones fue jamas fuente de una
  -- respuesta. Se pregunta a nivel de documento y no de fragmento: que un
  -- fragmento suelto no se haya citado no dice nada.
  AND NOT EXISTS (
        SELECT 1
        FROM core.documento_version v2
        JOIN core.chunk c2            ON c2.documento_version_id = v2.id
        JOIN core.respuesta_fuente rf ON rf.chunk_id = c2.id
        WHERE v2.documento_id = d.id)
ORDER BY a.nombre, d.codigo;

\echo ''
\echo '=== E) Satisfaccion: donde el sistema no esta sirviendo ==='

SELECT a.nombre                                              AS area,
       count(*)                                              AS con_feedback,
       count(*) FILTER (WHERE f.util)                        AS utiles,
       count(*) FILTER (WHERE NOT f.util)                    AS no_utiles,
       round(100.0 * count(*) FILTER (WHERE NOT f.util) / count(*), 1) AS pct_no_util
FROM core.feedback f
JOIN core.usuario u ON u.id = f.usuario_id
JOIN core.area a    ON a.id = u.area_id
GROUP BY a.nombre
ORDER BY pct_no_util DESC;

COMMIT;
