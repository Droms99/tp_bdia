-- =============================================================================
-- 05 - Row-Level Security
-- =============================================================================
-- Implementa D1 (informe 1.8): el control de acceso vive en el motor, no en la
-- aplicacion. La aplicacion abre la conexion como tp_lector y declara quien
-- pregunta con `SET LOCAL app.usuario_id = <id>` antes de cada consulta; a partir
-- de ahi, un SELECT sobre documento, documento_version o chunk devuelve solo lo
-- que ese usuario puede ver, sin que la consulta pueda evitarlo (R1).
--
-- La regla que se aplica es la de 4.4:
--
--   Acceso(u, d)  <=>  orden(nivel(d)) <= orden(habilitacion(u))
--                      AND ( nivel(d) es el minimo de la escala
--                            OR existe un otorgamiento vigente que alcance a u )
--
-- Vigencia (D3) queda deliberadamente fuera de esta regla: es un criterio de
-- recuperacion independiente del permiso, y lo aplica la consulta de
-- db/consultas/, no la politica de seguridad. Mezclar los dos ejes en la misma
-- politica le impediria al auditor consultar el historico derogado.
--
-- Los cuatro roles no comparten la misma politica, porque no cumplen la misma
-- funcion (informe 1.4):
--   tp_lector   filtrado por la regla de 4.4. Es el rol de conexion del RAG:
--               el que hace la busqueda "ciega al permiso" que D1 protege.
--   tp_curador  visibilidad completa: no puede clasificar, versionar ni derogar
--               lo que no ve.
--   tp_auditor  visibilidad completa, incluido el historico derogado.
--               "Restricciones minimas, definidas caso por caso" (informe 1.4).
--   tp_admin    visibilidad completa. No se usa para consultar desde la
--               aplicacion (02_esquemas_roles.sql).
--
-- tp_bdia (el dueño de las tablas) no tiene politica propia porque no hace
-- falta: es superusuario en este entorno de Docker y Postgres nunca aplica RLS
-- a un superusuario, tenga o no FORCE. FORCE se declara de todos modos porque
-- es lo correcto para un despliegue donde el dueño del esquema no sea superusuario.
-- =============================================================================

SET search_path = core, public;


-- =============================================================================
-- Funciones de chequeo de acceso
-- =============================================================================
-- SECURITY DEFINER: corren con los privilegios de quien las creo (el dueño de
-- las tablas), no con los de quien las llama. Es lo que permite que tp_lector
-- evalue la regla de 4.4 sin tener SELECT directo sobre acl_documento ni
-- usuario_rol, que son de las tablas mas sensibles del modelo (informe 3.3) y no
-- deberian poder consultarse libremente desde el rol de la aplicacion.
--
-- search_path fijo: una funcion SECURITY DEFINER que no fija el suyo es
-- vulnerable a que quien la llama redefina un objeto con el mismo nombre en un
-- esquema anterior en su propio search_path.
--
-- REVOKE de PUBLIC: a diferencia de las tablas, las funciones nuevas otorgan
-- EXECUTE a PUBLIC por omision. Sin el REVOKE, cualquier rol con USAGE sobre el
-- esquema core podria invocarlas.
-- =============================================================================

CREATE OR REPLACE FUNCTION core.puede_acceder_documento(p_documento_id bigint)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = core, pg_temp
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM core.documento d
        JOIN core.nivel_confidencialidad nd ON nd.id = d.nivel_id
        JOIN core.usuario u
            ON u.id = nullif(current_setting('app.usuario_id', true), '')::bigint
        JOIN core.nivel_confidencialidad nu ON nu.id = u.nivel_habilitacion_id
        WHERE d.id = p_documento_id
          -- El nivel del documento no puede superar la habilitacion del usuario.
          AND nd.orden <= nu.orden
          AND (
                -- El nivel minimo de la escala (publico) no exige otorgamiento.
                nd.orden = (SELECT min(orden) FROM core.nivel_confidencialidad)
             OR EXISTS (
                    SELECT 1
                    FROM core.acl_documento a
                    WHERE a.documento_id = d.id
                      AND now() >= a.vigente_desde
                      AND (a.vigente_hasta IS NULL OR now() < a.vigente_hasta)
                      AND (
                            a.usuario_id = u.id
                         OR a.area_id = u.area_id
                         OR a.rol_id IN (SELECT rol_id FROM core.usuario_rol WHERE usuario_id = u.id)
                      )
                )
          )
    );
$$;

COMMENT ON FUNCTION core.puede_acceder_documento(bigint) IS
    'Regla de acceso de 4.4. SECURITY DEFINER: evalua la ACL del usuario de la sesion sin exponer acl_documento ni usuario_rol a quien consulta.';

REVOKE ALL ON FUNCTION core.puede_acceder_documento(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.puede_acceder_documento(bigint) TO tp_lector;


CREATE OR REPLACE FUNCTION core.puede_acceder_chunk(p_documento_version_id bigint)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = core, pg_temp
AS $$
    -- Resuelve el documento sin pasar por la politica de documento_version: si
    -- lo hiciera con un SELECT comun, el chequeo quedaria anidado dentro de otra
    -- evaluacion de la misma regla en lugar de una unica evaluacion explicita.
    SELECT core.puede_acceder_documento(documento_id)
    FROM core.documento_version
    WHERE id = p_documento_version_id;
$$;

COMMENT ON FUNCTION core.puede_acceder_chunk(bigint) IS
    'Resuelve el documento de un chunk a partir de su version y aplica la misma regla de 4.4. El chunk no tiene clasificacion propia (RD1).';

REVOKE ALL ON FUNCTION core.puede_acceder_chunk(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.puede_acceder_chunk(bigint) TO tp_lector;


-- =============================================================================
-- Politicas de seguridad por fila
-- =============================================================================

-- -----------------------------------------------------------------------------
-- documento
-- -----------------------------------------------------------------------------

ALTER TABLE documento ENABLE ROW LEVEL SECURITY;
ALTER TABLE documento FORCE ROW LEVEL SECURITY;

CREATE POLICY documento_lector ON documento
    FOR SELECT TO tp_lector
    USING (core.puede_acceder_documento(id));

CREATE POLICY documento_gestion ON documento
    FOR ALL TO tp_curador, tp_admin
    USING (true) WITH CHECK (true);

CREATE POLICY documento_auditor ON documento
    FOR SELECT TO tp_auditor
    USING (true);


-- -----------------------------------------------------------------------------
-- documento_version
-- -----------------------------------------------------------------------------
-- Se protege igual que documento, y no solo chunk: documento_version.texto es el
-- texto completo extraido de la version. Sin politica propia, cualquiera con
-- SELECT sobre la tabla lo leeria entero sin pasar por la fragmentacion, lo que
-- rompe la garantia de D1 por una via distinta a la busqueda semantica.
-- -----------------------------------------------------------------------------

ALTER TABLE documento_version ENABLE ROW LEVEL SECURITY;
ALTER TABLE documento_version FORCE ROW LEVEL SECURITY;

CREATE POLICY documento_version_lector ON documento_version
    FOR SELECT TO tp_lector
    USING (core.puede_acceder_documento(documento_id));

CREATE POLICY documento_version_gestion ON documento_version
    FOR ALL TO tp_curador, tp_admin
    USING (true) WITH CHECK (true);

CREATE POLICY documento_version_auditor ON documento_version
    FOR SELECT TO tp_auditor
    USING (true);


-- -----------------------------------------------------------------------------
-- chunk
-- -----------------------------------------------------------------------------
-- Es la tabla que importa de verdad: es lo que entra al contexto del modelo de
-- lenguaje (informe 2.1.C). No guarda su propio nivel de confidencialidad
-- (RD1): la pertenencia a la version es la unica via para heredarlo.
-- -----------------------------------------------------------------------------

ALTER TABLE chunk ENABLE ROW LEVEL SECURITY;
ALTER TABLE chunk FORCE ROW LEVEL SECURITY;

CREATE POLICY chunk_lector ON chunk
    FOR SELECT TO tp_lector
    USING (core.puede_acceder_chunk(documento_version_id));

CREATE POLICY chunk_gestion ON chunk
    FOR ALL TO tp_curador, tp_admin
    USING (true) WITH CHECK (true);

CREATE POLICY chunk_auditor ON chunk
    FOR SELECT TO tp_auditor
    USING (true);


-- =============================================================================
-- Privilegios por tabla
-- =============================================================================
-- El detalle que 02_esquemas_roles.sql dejo pendiente. El criterio es el mismo
-- en toda la seccion: tp_lector es el rol de la aplicacion RAG y recibe el
-- minimo que le permite operar (nunca SELECT sobre acl_documento, usuario_rol
-- ni usuario, que resuelve la ACL sin exponerla; nunca sobre las tablas de
-- auditoria); tp_curador recibe lo que sus procesos (P1-P3) necesitan escribir;
-- tp_auditor recibe SELECT amplio y ninguna escritura; tp_admin administra.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- A. Estructura organizativa y control de acceso
-- -----------------------------------------------------------------------------

GRANT SELECT ON area, nivel_confidencialidad TO tp_lector, tp_curador, tp_auditor, tp_admin;
GRANT INSERT, UPDATE ON area, nivel_confidencialidad TO tp_admin;

GRANT SELECT ON rol, permiso, rol_permiso TO tp_curador, tp_auditor, tp_admin;
GRANT INSERT, UPDATE, DELETE ON rol, permiso, rol_permiso TO tp_admin;

-- usuario contiene datos personales (R7): tp_lector no lo consulta directamente,
-- solo a traves de las funciones de chequeo de acceso.
GRANT SELECT ON usuario, usuario_rol TO tp_curador, tp_auditor, tp_admin;
GRANT INSERT, UPDATE ON usuario TO tp_admin;
GRANT INSERT, UPDATE, DELETE ON usuario_rol TO tp_admin;

-- acl_documento es la tabla mas critica del modelo (informe 3.3). No se otorga
-- DELETE a tp_curador: revocar un permiso es cerrar su ventana de vigencia
-- (UPDATE de vigente_hasta), no borrar la fila, para no perder el historial de
-- quien tuvo acceso a que y hasta cuando.
GRANT SELECT, INSERT, UPDATE ON acl_documento TO tp_curador;
GRANT SELECT ON acl_documento TO tp_auditor;
GRANT SELECT, INSERT, UPDATE, DELETE ON acl_documento TO tp_admin;


-- -----------------------------------------------------------------------------
-- B. Catalogo documental, versiones y relaciones
-- -----------------------------------------------------------------------------

GRANT SELECT ON tipo_documento, modelo_embedding TO tp_lector, tp_curador, tp_auditor, tp_admin;
GRANT INSERT, UPDATE ON tipo_documento, modelo_embedding TO tp_admin;

-- documento y documento_version: SELECT para tp_lector queda acotado por las
-- politicas de RLS de arriba, no por este GRANT. No se otorga DELETE a nadie
-- salvo tp_admin: un documento no se borra, se deroga (D2, D3).
GRANT SELECT ON documento, documento_version TO tp_lector, tp_curador, tp_auditor, tp_admin;
GRANT INSERT, UPDATE ON documento, documento_version TO tp_curador, tp_admin;
GRANT DELETE ON documento, documento_version TO tp_admin;

-- documento_relacion y las etiquetas no se exponen a tp_lector: no aportan al
-- camino critico de recuperacion y documento_relacion revela la existencia de
-- documentos (por ejemplo, cuales derogan a cuales) sin pasar por la regla de
-- 4.4.
GRANT SELECT ON documento_relacion, etiqueta, documento_etiqueta TO tp_curador, tp_auditor, tp_admin;
GRANT INSERT ON documento_relacion, etiqueta, documento_etiqueta TO tp_curador, tp_admin;


-- -----------------------------------------------------------------------------
-- C. Contenido y fragmentos
-- -----------------------------------------------------------------------------

-- chunk: mismo criterio que documento_version. SELECT para tp_lector queda
-- acotado por la politica de RLS, no por este GRANT.
GRANT SELECT ON chunk TO tp_lector, tp_curador, tp_auditor, tp_admin;
GRANT INSERT, UPDATE ON chunk TO tp_curador, tp_admin;
GRANT DELETE ON chunk TO tp_admin;


-- -----------------------------------------------------------------------------
-- D. Uso del sistema
-- -----------------------------------------------------------------------------
-- De solo insercion desde la aplicacion (informe 3.2). tp_lector no tiene
-- SELECT: no hay requisito del caso que exija que un usuario pueda repasar el
-- historico de consultas de otro, y INSERT ... RETURNING no necesita SELECT
-- para que la aplicacion recupere el id que acaba de generar.
-- -----------------------------------------------------------------------------

GRANT INSERT ON consulta, respuesta, respuesta_fuente, feedback TO tp_lector, tp_admin;
GRANT SELECT ON consulta, respuesta, respuesta_fuente, feedback TO tp_auditor, tp_admin;


-- -----------------------------------------------------------------------------
-- E. Auditoria
-- -----------------------------------------------------------------------------
-- RD13: no admiten modificacion ni borrado. No se otorga UPDATE ni DELETE a
-- ningun rol, tp_admin incluido: la garantia es que nadie pueda alterarlas
-- desde la aplicacion, no que el administrador elija no hacerlo.
--
-- La poblacion real de auditoria via disparadores sobre las tablas sensibles
-- (RD4, RD5) queda pendiente; este GRANT solo prepara la superficie de permisos
-- para cuando existan.
-- -----------------------------------------------------------------------------

GRANT INSERT ON log_acceso TO tp_lector, tp_curador, tp_admin;
GRANT SELECT ON log_acceso TO tp_auditor, tp_admin;

GRANT INSERT ON auditoria TO tp_curador, tp_admin;
GRANT SELECT ON auditoria TO tp_auditor, tp_admin;
