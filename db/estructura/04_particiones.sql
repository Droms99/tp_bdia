-- =============================================================================
-- 04 - Particiones
-- =============================================================================
-- Las cinco tablas de eventos se declararon PARTITION BY RANGE (creado_en) en
-- 03_tablas.sql. Una tabla particionada sin particiones no acepta un solo INSERT:
-- este script tiene que correr antes de cargar cualquier dato.
--
-- Se generan particiones mensuales con un DO block en lugar de un CREATE TABLE
-- por mes y por tabla (60 sentencias para el rango elegido): el criterio de
-- particionado es el mismo para las cinco tablas y escribirlo cinco veces
-- introduce la posibilidad de que diverjan sin motivo.
--
-- El rango elegido (los doce meses de 2026) alcanza para cargar los datos de
-- ejemplo y para mostrar poda de particiones en el EXPLAIN de una consulta
-- filtrada por fecha, que es lo que exige la implementacion minima (crear
-- estructuras, cargar algunos datos, ejecutar las consultas representativas).
-- No se generan particiones para anios futuros ni se automatiza su creacion: en
-- produccion eso se resuelve con un job programado o con pg_partman, y es
-- justamente la pieza de arquitectura que la catedra aclaro que se analiza y se
-- justifica (punto 14 del informe), no se implementa fisicamente.
--
-- Cada tabla ademas recibe una particion DEFAULT: una red de seguridad para que
-- una fila con fecha fuera del rango declarado no rechace el INSERT (por ejemplo,
-- si el generador de datos sinteticos fecha algun evento fuera de 2026). No
-- deberia concentrar datos: si lo hace, es la senial de que hace falta extender
-- el rango de particiones explicitas.
-- =============================================================================

SET search_path = core, public;

DO $$
DECLARE
    tablas          text[] := ARRAY['consulta', 'respuesta', 'respuesta_fuente', 'log_acceso', 'auditoria'];
    tabla           text;
    mes             date;
    inicio          date := date '2026-01-01';
    fin             date := date '2027-01-01';  -- limite exclusivo: la ultima particion cubre diciembre 2026
    nombre_particion text;
BEGIN
    FOREACH tabla IN ARRAY tablas LOOP
        mes := inicio;
        WHILE mes < fin LOOP
            nombre_particion := format('%s_%s', tabla, to_char(mes, 'YYYY_MM'));
            EXECUTE format(
                'CREATE TABLE IF NOT EXISTS %I PARTITION OF %I FOR VALUES FROM (%L) TO (%L)',
                nombre_particion, tabla, mes, mes + interval '1 month'
            );
            mes := mes + interval '1 month';
        END LOOP;

        nombre_particion := tabla || '_default';
        EXECUTE format(
            'CREATE TABLE IF NOT EXISTS %I PARTITION OF %I DEFAULT',
            nombre_particion, tabla
        );
    END LOOP;
END
$$;

COMMENT ON TABLE consulta_default IS 'Red de seguridad: filas con creado_en fuera de 2026. No deberia recibir filas en operacion normal.';
COMMENT ON TABLE respuesta_default IS 'Red de seguridad: filas con creado_en fuera de 2026. No deberia recibir filas en operacion normal.';
COMMENT ON TABLE respuesta_fuente_default IS 'Red de seguridad: filas con creado_en fuera de 2026. No deberia recibir filas en operacion normal.';
COMMENT ON TABLE log_acceso_default IS 'Red de seguridad: filas con creado_en fuera de 2026. No deberia recibir filas en operacion normal.';
COMMENT ON TABLE auditoria_default IS 'Red de seguridad: filas con creado_en fuera de 2026. No deberia recibir filas en operacion normal.';
