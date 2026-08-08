-- =============================================================================
-- 02 - Esquemas y roles
-- =============================================================================
-- Los esquemas implementan la arquitectura por capas dentro de un unico motor
-- (informe, punto 12). Los roles implementan D1: el control de acceso vive en la
-- base, y para eso hace falta que quien consulta no sea el duenio de las tablas.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Esquemas
-- -----------------------------------------------------------------------------

CREATE SCHEMA IF NOT EXISTS raw;
COMMENT ON SCHEMA raw IS
    'Capa de aterrizaje: documentos tal como se reciben, antes de clasificar y fragmentar.';

CREATE SCHEMA IF NOT EXISTS core;
COMMENT ON SCHEMA core IS
    'Capa operacional: catalogo documental, fragmentos, permisos y uso del sistema.';

CREATE SCHEMA IF NOT EXISTS analytics;
COMMENT ON SCHEMA analytics IS
    'Capa analitica: agregaciones precalculadas. Por R8 no contiene texto de fragmentos.';


-- -----------------------------------------------------------------------------
-- Roles
-- -----------------------------------------------------------------------------
-- Se crean como roles de grupo (NOLOGIN): los usuarios reales de la base heredan
-- de ellos. Los perfiles se corresponden con los relevados en el informe 1.4.
--
-- IMPORTANTE: el duenio de una tabla ignora sus politicas RLS salvo que se declare
-- FORCE ROW LEVEL SECURITY. La aplicacion NUNCA debe conectarse con el rol duenio.
-- Eso se resuelve en 05_rls.sql.
-- -----------------------------------------------------------------------------

DO $$
BEGIN
    -- Consulta el sistema. Es el rol con el que se conecta la aplicacion RAG y
    -- sobre el que efectivamente actuan las politicas de seguridad por fila.
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'tp_lector') THEN
        CREATE ROLE tp_lector NOLOGIN;
    END IF;

    -- Carga, clasifica, versiona, publica y deroga documentos, y asigna permisos.
    -- Es el "curador documental" de 1.4: no consulta para obtener respuestas.
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'tp_curador') THEN
        CREATE ROLE tp_curador NOLOGIN;
    END IF;

    -- Auditor interno: accede al historico y a los registros de auditoria.
    -- Su existencia es la razon por la que vigencia y permiso son ejes separados (D3).
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'tp_auditor') THEN
        CREATE ROLE tp_auditor NOLOGIN;
    END IF;

    -- Administra la solucion. No se usa para consultar desde la aplicacion.
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'tp_admin') THEN
        CREATE ROLE tp_admin NOLOGIN;
    END IF;
END
$$;

COMMENT ON ROLE tp_lector  IS 'Consulta la documentacion autorizada. Rol de conexion de la aplicacion RAG.';
COMMENT ON ROLE tp_curador IS 'Mantiene el catalogo documental y asigna permisos.';
COMMENT ON ROLE tp_auditor IS 'Accede al historico derogado y a los registros de auditoria.';
COMMENT ON ROLE tp_admin   IS 'Administracion de la solucion.';


-- -----------------------------------------------------------------------------
-- Permisos sobre los esquemas
-- -----------------------------------------------------------------------------
-- El detalle por tabla se define en 05_rls.sql, junto con las politicas: separar
-- el GRANT de la politica que lo acota llevaria a leerlos por separado y es
-- justamente donde se cometen los errores de permisos.
-- -----------------------------------------------------------------------------

GRANT USAGE ON SCHEMA core      TO tp_lector, tp_curador, tp_auditor, tp_admin;
GRANT USAGE ON SCHEMA analytics TO tp_lector, tp_curador, tp_auditor, tp_admin;
GRANT USAGE ON SCHEMA raw       TO tp_curador, tp_admin;
