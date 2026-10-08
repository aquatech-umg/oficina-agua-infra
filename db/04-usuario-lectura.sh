#!/bin/bash
# Crea el usuario de solo lectura que usan los microservicios.
# Usuario y contrasena vienen de .env (DB_LECTURA_USER y DB_LECTURA_PASSWORD).
# Se ejecuta en la principal y llega a la replica por la replicacion.
set -e

mariadb -uroot --database=mysql <<EOSQL
CREATE USER IF NOT EXISTS '${DB_LECTURA_USER}'@'%' IDENTIFIED BY '${DB_LECTURA_PASSWORD}';
GRANT SELECT ON ${MARIADB_DATABASE}.* TO '${DB_LECTURA_USER}'@'%';
EOSQL