-- =============================================================================
-- Consulta 2 - Busqueda hibrida: vectorial + texto completo, fusionadas con RRF
-- =============================================================================
-- QUE PREGUNTA RESPONDE
--   "¿Que exige la Comunicacion A 7724 sobre autenticacion de dos factores?"
--
-- POR QUE ES UTIL
--   Las dos mitades de la recuperacion fallan en sentidos opuestos, y esta
--   pregunta lo muestra en un solo tiro:
--
--     - La busqueda vectorial entiende el sentido ("dos factores",
--       "autenticacion") pero es mala con un identificador exacto: para el
--       vector, "7724" se parece a "7511" y a "7890". Va a traer normativa
--       parecida que no es la pedida.
--     - La busqueda de texto completo encuentra "7724" con precision quirurgica,
--       pero no sabe que "verificacion en dos pasos" es lo mismo que
--       "autenticacion de dos factores".
--
--   Un detalle que importa: la mitad lexica NO usa plainto_tsquery. Esa funcion
--   combina los terminos con AND, y exige que el fragmento contenga todos: sobre
--   esta pregunta no devuelve una sola fila. Para recuperacion hibrida los
--   terminos van con OR, y el ranking se encarga de ordenar segun cuantos y cuan
--   bien coinciden. Es una diferencia de una linea que decide si la mitad lexica
--   aporta algo o no aporta nada.
--
--   Reciprocal Rank Fusion combina los dos rankings sumando 1/(k + posicion) de
--   cada uno. No necesita normalizar puntajes de escalas distintas —una
--   distancia coseno y un ts_rank no son comparables entre si— porque no usa los
--   puntajes: usa las posiciones. Un fragmento que sale bien rankeado en las dos
--   listas le gana a uno que sale primero en una sola.
--
--   La consulta ademas aplica los dos filtros que el caso exige: vigencia (D3),
--   que descarta lo derogado, y el permiso, que no esta escrito en ningun WHERE
--   porque lo impone la politica de seguridad de fila.
--
-- COMO CORRERLA
--   make psql   y despues   \i /scripts/consultas/02_busqueda_hibrida_rrf.sql
-- =============================================================================

\pset pager off
\set QUIET on
SELECT embedding::text AS vec, texto AS preg
FROM core.consulta
WHERE texto = 'que exige la comunicacion A 7724 sobre autenticacion de dos factores'
ORDER BY creado_en LIMIT 1 \gset
SELECT id AS uid FROM core.usuario WHERE email = 'lgimenez@banco-ejemplo.com.ar' \gset
\set QUIET off

\echo ''
\echo '# Pregunta:' :'preg'
\echo '# Usuario: Laura Gimenez (Operaciones, habilitacion interno)'

BEGIN;
SET LOCAL ROLE tp_lector;
SET LOCAL app.usuario_id = :uid;

-- k = 60 es el valor del trabajo original de RRF. Amortigua las primeras
-- posiciones: la diferencia entre el puesto 1 y el 2 pesa poco mas que la que
-- hay entre el 10 y el 11, que es lo que se quiere cuando ninguno de los dos
-- rankings es confiable por si solo.
\set k 60
\set n 40

WITH vigentes AS (
    -- Universo de fragmentos elegibles. El filtro de vigencia (D3) va aca, una
    -- sola vez, para que las dos mitades busquen sobre lo mismo. El filtro de
    -- permiso no aparece: lo aplica la politica de RLS sobre core.chunk.
    SELECT ch.id, ch.texto, ch.embedding, ch.tsv, ch.metadatos, d.codigo, d.titulo
    FROM core.chunk ch
    JOIN core.documento_version v ON v.id = ch.documento_version_id
    JOIN core.documento d         ON d.id = v.documento_id
    WHERE d.estado = 'vigente'
      AND v.vigente_desde <= current_date
      AND (v.vigente_hasta IS NULL OR v.vigente_hasta >= current_date)
),
vectorial AS (
    SELECT id, codigo, titulo, metadatos,
           row_number() OVER (ORDER BY embedding <=> :'vec'::vector) AS pos
    FROM vigentes
    ORDER BY embedding <=> :'vec'::vector
    LIMIT :n
),
consulta_lexica AS (
    -- Los lexemas de la pregunta unidos con OR. to_tsvector lematiza y quita
    -- acentos igual que la columna generada `tsv`, asi que los dos lados hablan
    -- el mismo idioma.
    SELECT array_to_string(
               tsvector_to_array(to_tsvector('public.espanol_unaccent', :'preg')),
               ' | ')::tsquery AS q
),
lexica AS (
    SELECT v.id, v.codigo, v.titulo, v.metadatos,
           row_number() OVER (ORDER BY ts_rank_cd(v.tsv, cl.q) DESC, v.id) AS pos
    FROM vigentes v, consulta_lexica cl
    WHERE v.tsv @@ cl.q
    ORDER BY ts_rank_cd(v.tsv, cl.q) DESC, v.id
    LIMIT :n
)
SELECT coalesce(vec.codigo, lex.codigo)          AS documento,
       coalesce(vec.metadatos, lex.metadatos) ->> 'seccion' AS seccion,
       vec.pos                                   AS pos_vectorial,
       lex.pos                                   AS pos_lexica,
       round((coalesce(1.0 / (:k + vec.pos), 0)
            + coalesce(1.0 / (:k + lex.pos), 0))::numeric, 6) AS rrf
FROM vectorial vec
FULL OUTER JOIN lexica lex ON lex.id = vec.id
ORDER BY rrf DESC, documento
LIMIT 10;

COMMIT;


-- -----------------------------------------------------------------------------
-- Las dos mitades por separado, para ver que aporta cada una
-- -----------------------------------------------------------------------------
\echo ''
\echo '=== Solo vectorial: entiende el sentido, confunde el numero de norma ==='

BEGIN;
SET LOCAL ROLE tp_lector;
SET LOCAL app.usuario_id = :uid;
SELECT d.codigo, ch.metadatos ->> 'seccion' AS seccion,
       round((1 - (ch.embedding <=> :'vec'::vector))::numeric, 4) AS similitud
FROM core.chunk ch
JOIN core.documento_version v ON v.id = ch.documento_version_id
JOIN core.documento d         ON d.id = v.documento_id
WHERE d.estado = 'vigente'
ORDER BY ch.embedding <=> :'vec'::vector
LIMIT 5;
COMMIT;

\echo ''
\echo '=== Solo texto completo: encuentra el numero exacto, ignora los sinonimos ==='

BEGIN;
SET LOCAL ROLE tp_lector;
SET LOCAL app.usuario_id = :uid;
WITH cl AS (
    SELECT array_to_string(
               tsvector_to_array(to_tsvector('public.espanol_unaccent', :'preg')),
               ' | ')::tsquery AS q
)
SELECT d.codigo, ch.metadatos ->> 'seccion' AS seccion,
       round(ts_rank_cd(ch.tsv, cl.q)::numeric, 6) AS rank_texto
FROM core.chunk ch
JOIN core.documento_version v ON v.id = ch.documento_version_id
JOIN core.documento d         ON d.id = v.documento_id,
     cl
WHERE d.estado = 'vigente' AND ch.tsv @@ cl.q
ORDER BY ts_rank_cd(ch.tsv, cl.q) DESC
LIMIT 5;
COMMIT;
