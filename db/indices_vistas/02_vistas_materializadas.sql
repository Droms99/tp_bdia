-- =============================================================================
-- 02 - Vistas materializadas
-- =============================================================================
-- De las cuatro vistas de la capa analitica que describe el informe (2.1.F),
-- se construye una sola: consultas sin cobertura. Las otras tres (documentos
-- mas citados, uso por area, antiguedad de lo consultado) son agregaciones del
-- mismo estilo sobre las mismas tablas, y no agregan nada nuevo a la
-- validacion del diseño; se describen y se justifican en el informe sin
-- construirse, siguiendo la aclaracion de la catedra sobre implementacion
-- minima.
--
-- Esta es la que se construye porque es la de mayor valor de negocio del
-- trabajo (informe 5, "Capa analitica"): identifica que preguntas no
-- encontraron ningun fragmento, es decir, que le falta a la documentacion.
-- Ninguna de las otras tres tiene ese mismo peso: agregan uso, esta encuentra
-- huecos.
-- =============================================================================

SET search_path = core, public;

CREATE MATERIALIZED VIEW analytics.consultas_sin_cobertura AS
SELECT
    c.id            AS consulta_id,
    c.creado_en,
    c.usuario_id,
    u.area_id,
    c.texto
FROM core.consulta c
JOIN core.usuario u ON u.id = c.usuario_id
LEFT JOIN core.respuesta r
    ON r.consulta_id = c.id AND r.creado_en = c.creado_en
LEFT JOIN core.respuesta_fuente rf
    ON rf.respuesta_id = r.id AND rf.creado_en = r.creado_en
-- Sin coberura = no se recupero ningun fragmento: ni la respuesta existe, ni
-- si existe tiene fuentes. Por R8 no se incluye texto de fragmentos ni de
-- documento: solo el texto de la pregunta, que es lo minimo indispensable para
-- que el curador entienda que falto documentar.
WHERE rf.chunk_id IS NULL
WITH NO DATA;

COMMENT ON MATERIALIZED VIEW analytics.consultas_sin_cobertura IS
    'Preguntas que no recuperaron ningun fragmento: el mapa de lo que falta documentar (informe 2.1.F). Vacia hasta el primer REFRESH tras cargar datos.';

-- Indice unico requerido para poder refrescar con REFRESH MATERIALIZED VIEW
-- CONCURRENTLY, que no bloquea las lecturas mientras se recalcula (relevante
-- para el punto 14: esta vista se refresca sobre consulta, la tabla de mayor
-- volumen de escritura del sistema).
CREATE UNIQUE INDEX idx_consultas_sin_cobertura_id
    ON analytics.consultas_sin_cobertura (consulta_id);

-- No se refresca aca: no hay datos cargados todavia. El REFRESH inicial es
-- responsabilidad de quien carga los datos de ejemplo (db/datos/), despues de
-- poblar consulta, respuesta y respuesta_fuente.
--   REFRESH MATERIALIZED VIEW CONCURRENTLY analytics.consultas_sin_cobertura;

-- Igual que en 05_rls.sql: tp_lector no la consulta. No es parte del camino
-- critico del RAG, y consulta.texto puede contener datos personales (R7); la
-- capa analitica la usa el curador para decidir que documentar, y el auditor
-- para revisar cobertura, no el usuario final.
GRANT SELECT ON analytics.consultas_sin_cobertura TO tp_curador, tp_auditor, tp_admin;
