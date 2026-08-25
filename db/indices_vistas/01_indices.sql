-- =============================================================================
-- 01 - Indices
-- =============================================================================
-- Cada indice se justifica contra una pregunta concreta del relevamiento
-- (informe, punto 2.2). El que no se pueda justificar asi, no va.
--
-- No se usa CREATE INDEX CONCURRENTLY: es un script de configuracion inicial
-- sobre una base recien creada, no una migracion contra una tabla en produccion
-- con escrituras activas. En un despliegue real, construir estos indices sobre
-- las tablas de eventos sin bloquear los INSERT que las alimentan es exactamente
-- el tipo de decision operativa que el punto 14 del informe analiza y justifica,
-- no que este script implementa.
-- =============================================================================

SET search_path = core, public;


-- -----------------------------------------------------------------------------
-- Busqueda semantica: "¿que fragmentos vigentes y autorizados responden mejor
-- a esta pregunta?" (informe 2.2, primera fila, camino critico).
--
-- HNSW y no IVFFlat: HNSW no necesita reconstruirse cuando cambia el volumen de
-- datos (IVFFlat si, porque su numero de listas se elige en funcion del tamaño
-- de la tabla en el momento de crearlo) y da mejor recall a igual latencia. El
-- costo es un build mas lento y mas memoria, aceptable para el volumen del caso
-- (informe 2.4).
--
-- vector_cosine_ops porque coseno es la metrica por defecto de
-- modelo_embedding.metrica: el indice tiene que usar la misma metrica con la
-- que se va a consultar, o no se usa.
-- -----------------------------------------------------------------------------

CREATE INDEX idx_chunk_embedding_hnsw
    ON chunk USING hnsw (embedding vector_cosine_ops);

COMMENT ON INDEX idx_chunk_embedding_hnsw IS
    'Busqueda por similitud semantica sobre los fragmentos (informe 2.2). Metrica coseno, consistente con modelo_embedding.metrica.';


-- -----------------------------------------------------------------------------
-- Busqueda de texto completo: "¿que dice la normativa sobre un termino exacto,
-- por ejemplo una comunicacion identificada por su numero?" (informe 2.2). La
-- busqueda semantica sola no distingue "Comunicacion A 7724" de otra parecida
-- (informe 4, "Busqueda hibrida con RRF").
-- -----------------------------------------------------------------------------

CREATE INDEX idx_chunk_tsv_gin
    ON chunk USING gin (tsv);

COMMENT ON INDEX idx_chunk_tsv_gin IS
    'Busqueda de texto completo en español sobre los fragmentos, para la mitad lexica de la recuperacion hibrida con RRF.';


-- -----------------------------------------------------------------------------
-- Tolerancia a errores de tipeo en el titulo del documento: busqueda de la
-- interfaz del curador, no del camino critico de recuperacion (informe, punto
-- 4, "pg_trgm sobre titulos").
-- -----------------------------------------------------------------------------

CREATE INDEX idx_documento_titulo_trgm
    ON documento USING gin (titulo gin_trgm_ops);

COMMENT ON INDEX idx_documento_titulo_trgm IS
    'Busqueda tolerante a errores de tipeo sobre el titulo del documento, para la interfaz del curador.';


-- -----------------------------------------------------------------------------
-- Metadatos variables por tipo de documento: "¿que documentos tienen un
-- metadato especifico de su tipo, por ejemplo el organismo emisor?" (informe
-- 2.2). Es la contrapartida de D6: JSONB sin este indice degrada a recorrido
-- secuencial sobre cualquier filtro por metadatos.
-- -----------------------------------------------------------------------------

CREATE INDEX idx_documento_metadatos_gin
    ON documento USING gin (metadatos);

COMMENT ON INDEX idx_documento_metadatos_gin IS
    'Filtrado por atributos variables de documento.metadatos (D6, informe 2.2).';


-- -----------------------------------------------------------------------------
-- Vigencia como criterio de recuperacion (D3): filtra por estado en cada
-- consulta del camino critico. Baja cardinalidad (cuatro valores), pero
-- combina bien en un bitmap AND con los indices de arriba en vez de forzar un
-- recorrido secuencial completo de documento.
-- -----------------------------------------------------------------------------

CREATE INDEX idx_documento_estado
    ON documento (estado);

COMMENT ON INDEX idx_documento_estado IS
    'Filtro de vigencia (D3): la recuperacion excluye documentos derogados u obsoletos salvo consulta explicita de auditoria.';


-- -----------------------------------------------------------------------------
-- acl_documento.documento_id: es el indice mas importante de esta lista, aunque
-- no responda una pregunta del punto 2.2 de forma directa. Es el que usa
-- core.puede_acceder_documento() (05_rls.sql) en cada fila que evalua la
-- politica de RLS: sin el, cada chequeo de acceso recorre acl_documento entera.
-- Como es la tabla que consulta la politica de seguridad en el camino critico
-- (informe 4, "Row-Level Security"), su costo es el costo de D1.
-- -----------------------------------------------------------------------------

CREATE INDEX idx_acl_documento_documento_id
    ON acl_documento (documento_id);

COMMENT ON INDEX idx_acl_documento_documento_id IS
    'Soporta el EXISTS por documento_id de core.puede_acceder_documento(): es el indice del que depende el costo de evaluar RLS en cada fila (D1).';


-- -----------------------------------------------------------------------------
-- Uso por area: "¿que consulta cada area y con que frecuencia?" (informe 2.2).
-- Se crea sobre la tabla particionada: Postgres propaga el indice a cada
-- particion existente y a las que se creen despues (informe 5.3).
-- -----------------------------------------------------------------------------

CREATE INDEX idx_consulta_usuario_id
    ON consulta (usuario_id);

COMMENT ON INDEX idx_consulta_usuario_id IS
    'Agregacion de uso por usuario/area (informe 2.2). Se propaga a todas las particiones de consulta.';


-- -----------------------------------------------------------------------------
-- Documentos mas citados como fuente: "donde esta el conocimiento que la
-- organizacion consulta" (informe 2.1.F, la primera vista de analytics).
-- -----------------------------------------------------------------------------

CREATE INDEX idx_respuesta_fuente_chunk_id
    ON respuesta_fuente (chunk_id);

COMMENT ON INDEX idx_respuesta_fuente_chunk_id IS
    'Agregacion de fragmentos y documentos mas citados como fuente (informe 2.1.F).';


-- -----------------------------------------------------------------------------
-- Auditoria de accesos: "¿quien accedio a este documento confidencial en los
-- ultimos noventa dias?" (informe 2.2).
-- -----------------------------------------------------------------------------

CREATE INDEX idx_log_acceso_documento_id
    ON log_acceso (documento_id);

COMMENT ON INDEX idx_log_acceso_documento_id IS
    'Responde quien accedio a un documento dado, acotado por fecha via la particion (informe 2.2).';


-- -----------------------------------------------------------------------------
-- Trazabilidad de cambios sobre una entidad puntual: "¿quien otorgo este
-- permiso, cuando, y sobre que documento?" (informe 2.2).
-- -----------------------------------------------------------------------------

CREATE INDEX idx_auditoria_entidad
    ON auditoria (entidad, entidad_id);

COMMENT ON INDEX idx_auditoria_entidad IS
    'Reconstruye el historial de cambios de una fila puntual (por ejemplo, un acl_documento) a partir de su tabla y su id (informe 2.2).';
