.PHONY: up down logs psql estado reset

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
