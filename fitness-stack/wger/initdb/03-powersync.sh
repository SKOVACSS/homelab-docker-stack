#!/bin/sh
# PowerSync (the wger phone app's sync service) keeps its bucket storage in
# its own schema inside the wger database, under its own login. Runs once,
# when the database volume is first created. Same as wger's own
# dev-postgres/initdb/03-powersync.sql, with the password from the env.
set -e
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<SQL
CREATE USER powersync_storage WITH PASSWORD '${POWERSYNC_STORAGE_PASSWORD}';
CREATE SCHEMA powersync AUTHORIZATION powersync_storage;
GRANT CONNECT ON DATABASE ${POSTGRES_DB} TO powersync_storage;
SQL
