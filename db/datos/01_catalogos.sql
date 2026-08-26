-- =============================================================================
-- 01 - Catalogos
-- =============================================================================
-- Los catalogos no los produce el generador: son parte del diseño, no datos de
-- ejemplo. Sus valores estan fijados en el modelo conceptual (informe, punto 4)
-- y cambiarlos cambia el modelo, no el conjunto de prueba. Por eso van como SQL
-- literal y versionado, y no como un CSV regenerable.
--
-- Orden de ejecucion de db/datos/:
--   01_catalogos.sql   este archivo
--   02_staging.sql     tablas de aterrizaje en raw + carga de los CSV
--   03_core.sql        raw -> core, resolviendo las claves subrogadas
--   04_cierre.sql      vista materializada, estadisticas y verificaciones
--
-- Requiere que db/estructura/ y db/indices_vistas/ ya hayan corrido.
-- =============================================================================

SET search_path = core, public;

BEGIN;

-- -----------------------------------------------------------------------------
-- Niveles de confidencialidad
-- -----------------------------------------------------------------------------
-- La clave es explicita y no generada: `orden` es lo que convierte el acceso en
-- una comparacion (`orden(documento) <= orden(habilitacion)`) y no en una
-- enumeracion de casos. Un nivel nuevo se intercala cambiando el orden, y la
-- regla de 4.4 sigue valiendo sin tocar la politica de RLS.
-- -----------------------------------------------------------------------------

INSERT INTO nivel_confidencialidad (id, nombre, orden, descripcion) VALUES
    (1, 'publico',     1, 'Puede leerlo cualquier persona del banco. No exige otorgamiento explicito.'),
    (2, 'interno',     2, 'Documentacion de uso interno. Exige otorgamiento vigente.'),
    (3, 'confidencial',3, 'Informacion sensible del negocio. Otorgamiento por area o rol.'),
    (4, 'restringido', 4, 'Circulo cerrado de personas. Otorgamiento nominal, nunca por area.');


-- -----------------------------------------------------------------------------
-- Areas
-- -----------------------------------------------------------------------------

INSERT INTO area (nombre, descripcion) VALUES
    ('Riesgos',           'Riesgo crediticio, de mercado y operacional.'),
    ('Compliance',        'Prevencion de lavado de activos y cumplimiento normativo.'),
    ('Tecnología',        'Sistemas, infraestructura y seguridad de la informacion.'),
    ('Operaciones',       'Sucursales, back office y canales de atencion.'),
    ('Legales',           'Asesoramiento juridico, contratos y proteccion de datos.'),
    ('Auditoría Interna', 'Control interno. Accede a todo lo que audita.');


-- -----------------------------------------------------------------------------
-- Tipos de documento
-- -----------------------------------------------------------------------------

INSERT INTO tipo_documento (codigo, nombre, descripcion) VALUES
    ('norma_externa',         'Norma externa',            'Normativa del regulador. El banco no la edita: la adopta.'),
    ('politica_interna',      'Politica interna',         'Define que se hace y por que. La aprueba el Directorio o una gerencia.'),
    ('procedimiento',         'Procedimiento',            'Define como se hace, paso a paso.'),
    ('instructivo',           'Instructivo',              'Detalle operativo de una tarea puntual.'),
    ('manual_sistema',        'Manual de sistema',        'Operacion o configuracion de un sistema.'),
    ('faq',                   'Preguntas frecuentes',     'Respuestas breves de consulta directa.'),
    ('documento_historico',   'Documento historico',      'Derogado. Se conserva por obligacion y no debe responder consultas.'),
    ('informe_investigacion', 'Informe de investigacion', 'Resultado de una investigacion o auditoria. Habitualmente restringido.');


-- -----------------------------------------------------------------------------
-- Roles y permisos de la aplicacion
-- -----------------------------------------------------------------------------
-- No confundir con los roles del motor (tp_lector, tp_curador, tp_auditor,
-- tp_admin de 02_esquemas_roles.sql). Estos describen que hace una persona en el
-- sistema; aquellos, con que privilegios se conecta la aplicacion. La politica
-- de RLS usa estos para resolver los otorgamientos por rol.
-- -----------------------------------------------------------------------------

INSERT INTO rol (nombre, descripcion) VALUES
    ('consultor',     'Consulta la documentacion que tiene autorizada.'),
    ('curador',       'Carga, clasifica, versiona, publica y deroga documentos de su area.'),
    ('auditor',       'Revisa accesos, trazabilidad y el historico derogado.'),
    ('administrador', 'Administra usuarios, catalogos y la configuracion de la solucion.');

INSERT INTO permiso (codigo, descripcion) VALUES
    ('consultar',           'Formular consultas y recibir respuestas con sus fuentes.'),
    ('documento.cargar',    'Incorporar un documento nuevo o una version nueva.'),
    ('documento.publicar',  'Pasar una version de borrador a vigente.'),
    ('documento.derogar',   'Marcar un documento como derogado y cerrar su vigencia.'),
    ('acceso.otorgar',      'Otorgar o revocar acceso a un documento.'),
    ('auditar',             'Consultar registros de acceso, auditoria e historico derogado.'),
    ('administrar',         'Administrar usuarios, roles y catalogos.');

INSERT INTO rol_permiso (rol_id, permiso_id)
SELECT r.id, p.id
FROM rol r
JOIN permiso p ON (
        (r.nombre = 'consultor'     AND p.codigo IN ('consultar'))
     OR (r.nombre = 'curador'       AND p.codigo IN ('consultar', 'documento.cargar',
                                                     'documento.publicar', 'documento.derogar',
                                                     'acceso.otorgar'))
     OR (r.nombre = 'auditor'       AND p.codigo IN ('consultar', 'auditar'))
     OR (r.nombre = 'administrador' AND p.codigo IN ('consultar', 'documento.cargar',
                                                     'documento.publicar', 'documento.derogar',
                                                     'acceso.otorgar', 'auditar', 'administrar'))
);


-- -----------------------------------------------------------------------------
-- Modelo de embeddings
-- -----------------------------------------------------------------------------
-- Sin este registro no hay forma de saber si dos vectores son comparables. El
-- modelo por defecto del trabajo es deterministico y local (etl/embeddings.py):
-- se eligio para que el repositorio pueda clonarse y reproducirse sin
-- credenciales ni costos. La dimension 1024 es la declarada en
-- chunk.embedding vector(1024) y en consulta.embedding.
-- -----------------------------------------------------------------------------

INSERT INTO modelo_embedding (nombre, dimension, metrica, activo, vigente_desde) VALUES
    ('hash-local-1024', 1024, 'coseno', true, DATE '2026-01-01');

COMMENT ON TABLE modelo_embedding IS
    'Modelo con el que se vectorizo cada fragmento. El modelo es intercambiable por diseño: cambiar de modelo con la misma dimension es una revectorizacion; cambiar de dimension exige una columna nueva.';

COMMIT;

\echo 'Catalogos cargados.'
