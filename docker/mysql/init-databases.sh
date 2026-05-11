#!/usr/bin/env bash
set -euo pipefail

mysql=( mysql --protocol=socket -uroot -p"${MYSQL_ROOT_PASSWORD}" )

for database in \
  syrus_production \
  syrus_production_cache \
  syrus_production_queue \
  syrus_production_cable
do
  "${mysql[@]}" <<SQL
CREATE DATABASE IF NOT EXISTS \`${database}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
GRANT ALL PRIVILEGES ON \`${database}\`.* TO '${MYSQL_USER}'@'%';
SQL
done

"${mysql[@]}" <<SQL
FLUSH PRIVILEGES;
SQL
