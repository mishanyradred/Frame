FROM postgres:16-alpine

COPY init.sql /docker-entrypoint-initdb.d/01-init.sql

HEALTHCHECK --interval=10s --timeout=5s --start-period=20s --retries=5 \
    CMD pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" || exit 1
