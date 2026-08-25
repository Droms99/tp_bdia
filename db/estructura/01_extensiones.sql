-- =============================================================================
-- 01 - Extensiones
-- =============================================================================
-- Cada extension responde a una necesidad identificada en el relevamiento
-- (informe, punto 2).
-- =============================================================================

-- Busqueda por similitud sobre los fragmentos (informe 2.1.C).
CREATE EXTENSION IF NOT EXISTS vector;

-- Hash SHA-256 de los archivos originales, para detectar reingesta (D5, R4).
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Normalizacion de acentos en la busqueda de texto completo: la documentacion
-- esta en espanol y las consultas de los usuarios rara vez se escriben con tildes.
CREATE EXTENSION IF NOT EXISTS unaccent;

-- Tolerancia a errores de tipeo en la busqueda por titulo de documento.
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- Habilita el operador de igualdad dentro de indices GiST, que sin esto solo
-- admiten tipos de rango. Lo necesita la restriccion de exclusion de RD2: a lo
-- sumo una version vigente por documento en cada instante.
CREATE EXTENSION IF NOT EXISTS btree_gist;


-- =============================================================================
-- Configuracion de busqueda de texto completo en espanol, sin acentos
-- =============================================================================
-- La configuracion 'spanish' que trae PostgreSQL lematiza pero no normaliza
-- acentos: 'gestion' y 'gestión' producen lexemas distintos. Se antepone el
-- diccionario unaccent al lematizador para que ambas formas colapsen.
--
-- Va en el esquema public para ser alcanzable desde cualquier search_path, y se
-- referencia siempre calificada en las columnas generadas.
-- =============================================================================

DROP TEXT SEARCH CONFIGURATION IF EXISTS public.espanol_unaccent;

CREATE TEXT SEARCH CONFIGURATION public.espanol_unaccent (COPY = pg_catalog.spanish);

ALTER TEXT SEARCH CONFIGURATION public.espanol_unaccent
    ALTER MAPPING FOR hword, hword_part, word
    WITH unaccent, spanish_stem;

COMMENT ON TEXT SEARCH CONFIGURATION public.espanol_unaccent IS
    'Configuracion de busqueda de texto completo en espanol con normalizacion de acentos.';
