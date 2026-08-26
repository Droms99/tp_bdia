-- =============================================================================
-- Consulta 6 - Recorrido recursivo de la cadena de derogaciones
-- =============================================================================
-- QUE PREGUNTA RESPONDE
--   "Esta politica que rige hoy, ¿a que derogo? ¿Y aquella a que habia derogado?
--    ¿Cual era la norma vigente en marzo de 2023?"
--
-- POR QUE ES UTIL
--   En un banco regulado la pregunta no es retorica. Para determinar si una
--   actuacion del pasado fue correcta hay que leer la norma que regia EN ESE
--   MOMENTO, no la que rige hoy. Por eso la politica de conservacion
--   (DOC-LEG-007) conserva la normativa derogada sin plazo, y por eso el estado
--   de vigencia es parte del criterio de recuperacion y no un dato decorativo:
--   lo derogado se conserva y se puede recorrer, pero no alimenta respuestas.
--
--   Las relaciones entre documentos forman un grafo dirigido. Es un grafo real
--   pero chico y poco profundo, y esa es exactamente la razon por la que el
--   trabajo NO suma una base de grafos: `WITH RECURSIVE` lo recorre en una
--   consulta, dentro del mismo motor que ya tiene los permisos y las versiones.
--   Sacarlo a Neo4j significaria mantener sincronizados dos almacenes para
--   resolver un recorrido de tres saltos.
--
--   Se ejecuta como tp_auditor: `documento_relacion` no se le otorga a
--   tp_lector (05_rls.sql) porque revela la existencia de documentos —cuales
--   derogan a cuales— sin pasar por la regla de acceso.
--
-- COMO CORRERLA
--   make psql   y despues   \i /scripts/consultas/06_cadena_de_derogacion.sql
-- =============================================================================

\pset pager off

BEGIN;
SET LOCAL ROLE tp_auditor;

\echo ''
\echo '=== A) Hacia atras: de la politica vigente a todo lo que dejo sin efecto ==='

WITH RECURSIVE cadena AS (
    -- Caso base: el documento del que se parte.
    SELECT d.id, d.codigo, d.titulo, d.estado, 0 AS salto,
           d.codigo::text AS camino
    FROM core.documento d
    WHERE d.codigo = 'DOC-TEC-021'

    UNION ALL

    -- Paso recursivo: lo que el documento alcanzado deroga o reemplaza.
    SELECT dst.id, dst.codigo, dst.titulo, dst.estado, c.salto + 1,
           c.camino || ' -> ' || dst.codigo
    FROM cadena c
    JOIN core.documento_relacion r ON r.documento_origen_id = c.id
                                   AND r.tipo IN ('deroga', 'reemplaza')
    JOIN core.documento dst        ON dst.id = r.documento_destino_id
    -- Corte de seguridad: RD5 (ausencia de ciclos en documento_relacion) todavia
    -- no esta garantizada por un disparador. Sin este limite, un ciclo cargado
    -- por error haria que la consulta no termine nunca.
    WHERE c.salto < 10
)
SELECT salto, codigo, left(titulo, 48) AS titulo, estado, camino
FROM cadena
ORDER BY salto;

\echo ''
\echo '=== B) Vigencia de cada eslabon: que regia en cada momento ==='

WITH RECURSIVE cadena AS (
    SELECT d.id, d.codigo, 0 AS salto
    FROM core.documento d WHERE d.codigo = 'DOC-TEC-021'
    UNION ALL
    SELECT dst.id, dst.codigo, c.salto + 1
    FROM cadena c
    JOIN core.documento_relacion r ON r.documento_origen_id = c.id
                                   AND r.tipo IN ('deroga', 'reemplaza')
    JOIN core.documento dst        ON dst.id = r.documento_destino_id
    WHERE c.salto < 10
)
SELECT c.salto,
       c.codigo,
       v.numero_version                           AS version,
       v.vigente_desde,
       coalesce(v.vigente_hasta::text, 'sin cierre') AS vigente_hasta,
       d.estado,
       (SELECT count(*) FROM core.chunk ch WHERE ch.documento_version_id = v.id) AS fragmentos
FROM cadena c
JOIN core.documento d         ON d.id = c.id
JOIN core.documento_version v ON v.documento_id = c.id
ORDER BY v.vigente_desde;

\echo ''
\echo '=== C) La prueba de que lo derogado no responde consultas (D3) ==='
-- Los documentos derogados estan cargados, tienen fragmentos y tienen su vector.
-- Son perfectamente recuperables por similitud. Lo unico que impide que
-- alimenten una respuesta es el filtro de vigencia de las consultas de
-- recuperacion. Esta comparacion lo muestra sobre los datos cargados.

SELECT d.estado,
       count(DISTINCT d.id)      AS documentos,
       count(DISTINCT ch.id)     AS fragmentos_con_vector,
       count(rf.chunk_id)        AS veces_citados_como_fuente
FROM core.documento d
JOIN core.documento_version v      ON v.documento_id = d.id
JOIN core.chunk ch                 ON ch.documento_version_id = v.id
LEFT JOIN core.respuesta_fuente rf ON rf.chunk_id = ch.id
GROUP BY d.estado
ORDER BY d.estado;

\echo ''
\echo '=== D) El grafo completo de relaciones entre documentos ==='
-- Cuatro tipos de arista, no solo derogacion: complementa y referencia describen
-- dependencias que tambien importan. Antes de derogar un documento conviene
-- saber quien lo referencia.

SELECT r.tipo,
       o.codigo   AS origen,
       dst.codigo AS destino,
       dst.estado AS estado_destino
FROM core.documento_relacion r
JOIN core.documento o   ON o.id = r.documento_origen_id
JOIN core.documento dst ON dst.id = r.documento_destino_id
ORDER BY r.tipo, o.codigo;

\echo ''
\echo '=== E) Documentos vigentes que referencian a uno derogado ==='
-- El caso que rompe la confianza en la documentacion: una politica vigente que
-- remite a una norma que ya no rige. Es la consulta que deberia correr el
-- curador cada vez que deroga algo.
--
-- Se excluyen 'deroga' y 'reemplaza': esas relaciones apuntan a un documento
-- derogado por definicion, y contarlas ahogaria el hallazgo en ruido. Lo que se
-- busca es una referencia o una complementariedad colgada.
--
-- Sobre este corpus devuelve cero filas, y eso es el resultado correcto: no hay
-- referencias rotas. La consulta es el control, no el hallazgo.

SELECT o.codigo   AS documento_vigente,
       left(o.titulo, 45) AS titulo,
       r.tipo     AS relacion,
       dst.codigo AS apunta_a,
       dst.estado AS estado_del_destino
FROM core.documento_relacion r
JOIN core.documento o   ON o.id = r.documento_origen_id
JOIN core.documento dst ON dst.id = r.documento_destino_id
WHERE o.estado = 'vigente'
  AND dst.estado IN ('derogado', 'obsoleto')
  AND r.tipo NOT IN ('deroga', 'reemplaza')
ORDER BY o.codigo;


-- =============================================================================
-- Observacion sobre RD5 (ausencia de ciclos en documento_relacion)
-- =============================================================================
-- El punto 5.6 del informe deja RD5 pendiente de un disparador. Los datos
-- cargados muestran que, ademas, la restriccion esta enunciada de mas:
--
--   DOC-RIE-001 --complementa--> DOC-RIE-005
--   DOC-RIE-005 --complementa--> DOC-RIE-001
--
-- Eso es un ciclo, y es correcto: dos politicas pueden complementarse mutuamente
-- y de hecho asi estan escritas. Lo que no puede tener ciclos es la derogacion,
-- porque un documento no puede derogar a quien lo derogo. Cuando se escriba el
-- disparador, RD5 deberia acotarse a 'deroga' y 'reemplaza', no a las cuatro
-- aristas. Queda anotado como observacion, no como correccion: reformular una
-- restriccion del dominio es una decision del modelo, no de las consultas.
-- =============================================================================

COMMIT;
