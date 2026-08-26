-- =============================================================================
-- 04 - Cierre de la carga
-- =============================================================================
-- Refresca la vista materializada, actualiza las estadisticas del planificador y
-- verifica que lo cargado sea coherente con lo que el modelo afirma. Las
-- verificaciones no son decorativas: si alguna devuelve filas, la carga esta mal
-- y las consultas representativas medirian sobre datos que contradicen el diseño.
-- =============================================================================

SET search_path = core, public;

-- La vista se creo WITH NO DATA porque no habia datos. Este es su primer
-- refresco. Se hace sin CONCURRENTLY: la vista esta vacia y CONCURRENTLY no
-- puede refrescar una vista que nunca se poblo.
REFRESH MATERIALIZED VIEW analytics.consultas_sin_cobertura;

-- Sin esto el planificador trabaja con estimaciones por omision y el EXPLAIN de
-- las consultas representativas no refleja lo que haria con datos reales. Sobre
-- una tabla recien cargada es obligatorio, no opcional.
ANALYZE;

\echo ''
\echo '=== Volumen cargado ==='
SELECT 'area'                AS tabla, count(*) FROM area
UNION ALL SELECT 'usuario',            count(*) FROM usuario
UNION ALL SELECT 'usuario_rol',        count(*) FROM usuario_rol
UNION ALL SELECT 'documento',          count(*) FROM documento
UNION ALL SELECT 'documento_version',  count(*) FROM documento_version
UNION ALL SELECT 'documento_relacion', count(*) FROM documento_relacion
UNION ALL SELECT 'etiqueta',           count(*) FROM etiqueta
UNION ALL SELECT 'documento_etiqueta', count(*) FROM documento_etiqueta
UNION ALL SELECT 'acl_documento',      count(*) FROM acl_documento
UNION ALL SELECT 'chunk',              count(*) FROM chunk
UNION ALL SELECT 'consulta',           count(*) FROM consulta
UNION ALL SELECT 'respuesta',          count(*) FROM respuesta
UNION ALL SELECT 'respuesta_fuente',   count(*) FROM respuesta_fuente
UNION ALL SELECT 'feedback',           count(*) FROM feedback
UNION ALL SELECT 'log_acceso',         count(*) FROM log_acceso
UNION ALL SELECT 'auditoria',          count(*) FROM auditoria
UNION ALL SELECT 'consultas_sin_cobertura (vm)', count(*) FROM analytics.consultas_sin_cobertura
ORDER BY 1;

\echo ''
\echo '=== Verificaciones (toda fila devuelta es un error) ==='

\echo '-- V1: fragmentos sin vector'
SELECT count(*) AS filas FROM chunk WHERE embedding IS NULL;

\echo '-- V2: versiones cuyo texto no produjo ningun fragmento'
SELECT count(*) AS filas
FROM documento_version v
LEFT JOIN chunk c ON c.documento_version_id = v.id
WHERE c.id IS NULL;

\echo '-- V3: ordenes de fragmento no consecutivos desde 0 dentro de una version (RD9)'
SELECT count(*) AS filas FROM (
    SELECT documento_version_id
    FROM chunk
    GROUP BY documento_version_id
    HAVING max(orden) <> count(*) - 1 OR min(orden) <> 0
) t;

\echo '-- V4: fuentes citadas de un documento que el autor de la consulta no podia ver (RD11)'
-- Reimplementa la regla de 4.4 fuera de la politica de RLS, a proposito: si la
-- politica tuviera un error, una verificacion que la usara no lo detectaria.
SELECT count(*) AS filas
FROM respuesta_fuente rf
JOIN respuesta rp ON rp.id = rf.respuesta_id AND rp.creado_en = rf.creado_en
JOIN consulta c   ON c.id = rp.consulta_id   AND c.creado_en  = rp.creado_en
JOIN usuario u    ON u.id = c.usuario_id
JOIN nivel_confidencialidad nu ON nu.id = u.nivel_habilitacion_id
JOIN chunk ch     ON ch.id = rf.chunk_id
JOIN documento_version v ON v.id = ch.documento_version_id
JOIN documento d  ON d.id = v.documento_id
JOIN nivel_confidencialidad nd ON nd.id = d.nivel_id
WHERE nd.orden > nu.orden
   OR (nd.orden > (SELECT min(orden) FROM nivel_confidencialidad)
       AND NOT EXISTS (
           SELECT 1 FROM acl_documento a
           WHERE a.documento_id = d.id
             AND c.creado_en >= a.vigente_desde
             AND (a.vigente_hasta IS NULL OR c.creado_en < a.vigente_hasta)
             AND (a.usuario_id = u.id
                  OR a.area_id = u.area_id
                  OR a.rol_id IN (SELECT rol_id FROM usuario_rol WHERE usuario_id = u.id))));

\echo '-- V5: fuentes citadas de un documento derogado u obsoleto (D3)'
SELECT count(*) AS filas
FROM respuesta_fuente rf
JOIN chunk ch ON ch.id = rf.chunk_id
JOIN documento_version v ON v.id = ch.documento_version_id
JOIN documento d ON d.id = v.documento_id
WHERE d.estado IN ('derogado', 'obsoleto', 'borrador');

\echo '-- V6: fuentes citadas de una version cuya vigencia ya habia cerrado (D3)'
SELECT count(*) AS filas
FROM respuesta_fuente rf
JOIN chunk ch ON ch.id = rf.chunk_id
JOIN documento_version v ON v.id = ch.documento_version_id
WHERE v.vigente_hasta IS NOT NULL AND v.vigente_hasta < rf.creado_en::date;

\echo '-- V7: respuestas sin ninguna fuente citada (contradice D4)'
SELECT count(*) AS filas
FROM respuesta rp
LEFT JOIN respuesta_fuente rf ON rf.respuesta_id = rp.id AND rf.creado_en = rp.creado_en
WHERE rf.chunk_id IS NULL;

\echo '-- V8: eventos que cayeron en la particion DEFAULT (fuera del rango 2026)'
SELECT (SELECT count(*) FROM consulta_default)         AS consulta,
       (SELECT count(*) FROM respuesta_default)        AS respuesta,
       (SELECT count(*) FROM respuesta_fuente_default) AS respuesta_fuente,
       (SELECT count(*) FROM log_acceso_default)       AS log_acceso,
       (SELECT count(*) FROM auditoria_default)        AS auditoria;

\echo ''
\echo 'Carga finalizada.'
