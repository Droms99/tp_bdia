.PHONY: up down logs psql estado reset venv dataset estructura cargar consultas todo

# Levanta PostgreSQL con pgvector. Requiere Docker Desktop abierto.
up:
	docker compose up -d
	@echo "Esperando a que la base este lista..."
	@until docker compose exec -T db pg_isready -q; do sleep 1; done
	@echo "Base disponible en localhost:$${POSTGRES_PORT:-5433}"

down:
	docker compose down

logs:
	docker compose logs -f db

# Abre una sesion psql dentro del contenedor (no hace falta tener psql instalado en la maquina).
psql:
	docker compose exec db psql -U $${POSTGRES_USER:-tp_bdia} -d $${POSTGRES_DB:-tp_bdia}

# Verifica que las extensiones que necesita el modelo esten disponibles en la imagen.
estado:
	docker compose exec -T db psql -U $${POSTGRES_USER:-tp_bdia} -d $${POSTGRES_DB:-tp_bdia} \
		-c "SELECT name, default_version, installed_version FROM pg_available_extensions WHERE name IN ('vector','pg_trgm','unaccent','pgcrypto') ORDER BY name;"

# Borra el volumen: se pierden todos los datos y se vuelve a empezar de cero.
reset:
	docker compose down -v


# -----------------------------------------------------------------------------
# Datos de ejemplo y consultas (puntos 9 y 10 del informe)
# -----------------------------------------------------------------------------

PY := ./.venv/bin/python

# Entorno de Python para el ETL. El corpus esta en siete formatos y hace falta
# una biblioteca por formato para leerlo (etl/requirements.txt).
venv:
	python3 -m venv .venv
	./.venv/bin/pip install -q --upgrade pip
	./.venv/bin/pip install -q -r etl/requirements.txt
	@echo "Entorno listo en .venv"

# Regenera el conjunto de datos a partir del corpus. Con la misma semilla el
# resultado es identico: la salida no se versiona porque se reproduce.
dataset:
	$(PY) -m etl.generar_dataset

# Crea esquemas, tablas, particiones, politicas de seguridad, indices y vistas.
estructura:
	docker compose exec -T db psql -U $${POSTGRES_USER:-tp_bdia} -d $${POSTGRES_DB:-tp_bdia} \
		-v ON_ERROR_STOP=1 -q \
		-f /scripts/estructura/01_extensiones.sql \
		-f /scripts/estructura/02_esquemas_roles.sql \
		-f /scripts/estructura/03_tablas.sql \
		-f /scripts/estructura/04_particiones.sql \
		-f /scripts/estructura/05_rls.sql \
		-f /scripts/indices_vistas/01_indices.sql \
		-f /scripts/indices_vistas/02_vistas_materializadas.sql

# Carga los datos y corre las ocho verificaciones de coherencia del cierre.
cargar:
	docker compose exec -T db psql -U $${POSTGRES_USER:-tp_bdia} -d $${POSTGRES_DB:-tp_bdia} \
		-v ON_ERROR_STOP=1 -q \
		-f /scripts/datos/01_catalogos.sql \
		-f /scripts/datos/02_staging.sql \
		-f /scripts/datos/03_core.sql
	docker compose exec -T db psql -U $${POSTGRES_USER:-tp_bdia} -d $${POSTGRES_DB:-tp_bdia} \
		-f /scripts/datos/04_cierre.sql

# Ejecuta las seis consultas representativas, en orden.
consultas:
	@for f in db/consultas/*.sql; do \
		echo ""; echo "################ $$(basename $$f)"; \
		docker compose exec -T db psql -U $${POSTGRES_USER:-tp_bdia} -d $${POSTGRES_DB:-tp_bdia} \
			-f /scripts/consultas/$$(basename $$f); \
	done

# De cero a todo cargado y consultado. Borra el volumen: se pierden los datos.
todo: reset up dataset estructura cargar consultas
