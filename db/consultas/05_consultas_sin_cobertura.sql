-- =============================================================================
-- Consulta 5 - Consultas sin cobertura: el mapa de lo que falta documentar
-- =============================================================================
-- QUE PREGUNTA RESPONDE
--   "¿Que le esta preguntando la gente al sistema que la documentacion no
--    responde?"
--
-- POR QUE ES UTIL
--   Es, probablemente, la consulta de mayor valor de negocio del trabajo, y la
--   unica que produce informacion que antes no existia en ningun lado.
--
--   Las demas consultas explotan datos que la organizacion ya tenia de alguna
--   forma: quien accedio a que, que dice tal norma, que documento reemplaza a
--   cual. Esta produce algo nuevo: la lista de preguntas que la gente
--   efectivamente necesita responder y para las cuales no hay documento. Antes
--   del sistema, esa informacion se perdia —la persona preguntaba, no encontraba,
--   y resolvia por otro lado sin que quedara rastro—. Ahora queda registrada,
--   agrupada y priorizada por frecuencia.
--
--   Esta materializada porque recorre `consulta`, que es la tabla de mayor
--   volumen de escritura del sistema, y porque nadie necesita este dato al
--   segundo: es insumo de una decision de curaduria, no del camino critico.
--
--   Se ejecuta como tp_curador: es quien decide que documentar. tp_lector no la
--   tiene otorgada, porque `consulta.texto` puede contener datos personales en
--   texto libre (R7) y no hay motivo para que un usuario lea las preguntas de
--   los demas.
--
-- COMO CORRERLA
--   make psql   y despues   \i /scripts/consultas/05_consultas_sin_cobertura.sql
-- =============================================================================

\pset pager off

BEGIN;
SET LOCAL ROLE tp_curador;

\echo ''
\echo '=== A) Las preguntas sin respuesta, por frecuencia ==='

SELECT count(*)                         AS veces_preguntada,
       count(DISTINCT sc.usuario_id)    AS personas_distintas,
       min(sc.creado_en)::date          AS primera_vez,
       max(sc.creado_en)::date          AS ultima_vez,
       sc.texto                         AS pregunta
FROM analytics.consultas_sin_cobertura sc
GROUP BY sc.texto
ORDER BY veces_preguntada DESC, pregunta;

\echo ''
\echo '=== B) Por area que pregunta: donde falta documentacion ==='
-- El area del que pregunta no es necesariamente el area que deberia documentar,
-- pero es la mejor pista disponible: si Operaciones pregunta cinco veces por
-- comercio exterior, alguien tiene que escribir ese procedimiento.

SELECT a.nombre                                       AS area_que_pregunta,
       count(*)                                       AS consultas_sin_cobertura,
       count(DISTINCT sc.texto)                       AS temas_distintos,
       round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct_del_total
FROM analytics.consultas_sin_cobertura sc
JOIN core.area a ON a.id = sc.area_id
GROUP BY a.nombre
ORDER BY consultas_sin_cobertura DESC;

COMMIT;


-- =============================================================================
-- Hallazgo: la vista confunde dos causas distintas
-- =============================================================================
-- "Sin cobertura" esta definido como "la consulta no cito ninguna fuente". Eso
-- ocurre por dos motivos que la vista no distingue:
--
--   1. No existe documentacion sobre el tema. Es el caso que le interesa al
--      curador: hay que escribir el documento.
--   2. La documentacion existe, pero quien pregunto no tenia permiso para verla.
--      El curador no tiene que escribir nada; a lo sumo hay que revisar el
--      otorgamiento, o nada en absoluto si la restriccion es correcta.
--
-- Confundirlos tiene un costo concreto: el curador escribe un documento que ya
-- existe. El discriminador esta en los propios datos y no hace falta inventarlo:
-- si la misma pregunta le fue respondida a otra persona, la documentacion
-- existe. Se deja como observacion sobre la definicion de la vista, no como
-- correccion: cambiarla es una decision de diseño de la capa analitica.
--
-- Requiere tp_auditor: el denominador vive en `core.consulta`, sobre la que
-- tp_curador no tiene SELECT (05_rls.sql). Es una consecuencia deliberada del
-- esquema de permisos —el curador decide que documentar, no audita el uso— pero
-- vale registrar que le impide calcular esta apertura por si mismo.
-- =============================================================================

BEGIN;
SET LOCAL ROLE tp_auditor;

\echo ''
\echo '=== C) Las dos causas, separadas ==='

WITH respondidas_alguna_vez AS (
    SELECT DISTINCT c.texto
    FROM core.consulta c
    JOIN core.respuesta rp ON rp.consulta_id = c.id AND rp.creado_en = c.creado_en
)
SELECT CASE WHEN r.texto IS NULL
            THEN '1. Falta documentacion (nadie obtuvo respuesta nunca)'
            ELSE '2. Existe, pero quien pregunto no tenia permiso'
       END                          AS causa,
       count(*)                     AS consultas,
       count(DISTINCT sc.texto)     AS temas_distintos
FROM analytics.consultas_sin_cobertura sc
LEFT JOIN respondidas_alguna_vez r ON r.texto = sc.texto
GROUP BY 1
ORDER BY 1;

\echo ''
\echo '=== D) Detalle de la causa 2: preguntas bloqueadas por permiso ==='

WITH respondidas_alguna_vez AS (
    SELECT DISTINCT c.texto
    FROM core.consulta c
    JOIN core.respuesta rp ON rp.consulta_id = c.id AND rp.creado_en = c.creado_en
)
SELECT u.nombre                     AS pregunto,
       n.nombre                     AS habilitacion,
       a.nombre                     AS area,
       sc.texto                     AS pregunta
FROM analytics.consultas_sin_cobertura sc
JOIN respondidas_alguna_vez r ON r.texto = sc.texto
JOIN core.usuario u                ON u.id = sc.usuario_id
JOIN core.area a                   ON a.id = u.area_id
JOIN core.nivel_confidencialidad n ON n.id = u.nivel_habilitacion_id
ORDER BY u.nombre, sc.creado_en;

\echo ''
\echo '=== E) Evolucion mensual ==='
-- Si la proporcion baja mes a mes, la curaduria esta cerrando los huecos. Si se
-- mantiene, se esta documentando lo que no se pregunta.

SELECT date_trunc('month', c.creado_en)::date            AS mes,
       count(*)                                          AS consultas,
       count(sc.consulta_id)                             AS sin_cobertura,
       round(100.0 * count(sc.consulta_id) / count(*), 1) AS pct
FROM core.consulta c
LEFT JOIN analytics.consultas_sin_cobertura sc
       ON sc.consulta_id = c.id AND sc.creado_en = c.creado_en
GROUP BY 1
ORDER BY 1;

\echo ''
\echo '=== F) Que NO aparece en la vista, y por que importa ==='
-- La vista contiene el texto de la pregunta y nada mas: ni el texto de los
-- fragmentos, ni el de los documentos. Es deliberado (R8). La capa analitica
-- vive en un esquema al que acceden roles distintos de los del camino critico;
-- si arrastrara contenido documental, el control de acceso que la politica de
-- RLS sostiene sobre `chunk` se evitaria dando vuelta por `analytics`.

-- information_schema no lista vistas materializadas: no son parte del estandar
-- SQL. Hay que ir al catalogo propio de PostgreSQL.
SELECT string_agg(a.attname, ', ' ORDER BY a.attnum) AS columnas_de_la_vista
FROM pg_attribute a
JOIN pg_class c     ON c.oid = a.attrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'analytics'
  AND c.relname = 'consultas_sin_cobertura'
  AND a.attnum > 0 AND NOT a.attisdropped;

COMMIT;
