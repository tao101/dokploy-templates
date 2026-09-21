#!/bin/bash
# Postgres 15 -> 17 in-place upgrade for a Supabase stack deployed with these
# templates on Dokploy. Adapted from supabase/supabase docker/utils/upgrade-pg17.sh
# (same pg_upgrade helper scripts), with the Dokploy paths and container names.
#
# Usage (as root on the Dokploy host, stack STOPPED in Dokploy for the 'upgrade' phase):
#   APP=<dokploy appName> PREFIX=<CONTAINER_PREFIX> CURRENT_IMAGE=supabase/postgres:15.8.1.xxx \
#     bash upgrade-pg17-dokploy.sh build     # builds the pg17 binaries tarball (stack may run)
#     bash upgrade-pg17-dokploy.sh upgrade   # pg_upgrade; needs the stack stopped
#     ... paste the current compose/env in Dokploy and Deploy ...
#     bash upgrade-pg17-dokploy.sh post      # PG17 migrations + extension reconcile (stack running)
#
# Data dir: /etc/dokploy/compose/$APP/files/volumes/db/data (kept as data.bak.pg15 for rollback).
# The pgsodium key is read from the old named volume ${APP}_db-config (old templates) or
# from files/volumes/db/config (current template) and written to files/volumes/db/config.
#
# Gotchas learned the hard way:
#  * Never start the PG17 image on a PG15 data dir: it refuses to start, but its entrypoint
#    chowns the whole data dir to uid 100 (PG15's postgres is uid 105) and leaves a
#    postmaster.pid the PG15 helper cannot open. The 'upgrade' phase fixes ownership first.
#  * PG15 in the helper container needs up to ~2 min of recovery before pg_isready succeeds.
set -euo pipefail
: "${APP:?APP (dokploy appName) required}"; : "${PREFIX:?PREFIX (CONTAINER_PREFIX) required}"; : "${CURRENT_IMAGE:?CURRENT_IMAGE required}"
UPGRADE_IMAGE=${UPGRADE_IMAGE:-supabase/postgres:17.6.1.063}
TARGET_IMAGE=${TARGET_IMAGE:-supabase/postgres:17.6.1.136}
SCRIPTS_REF=${SCRIPTS_REF:-17.6.1.063}
BASE=/etc/dokploy/compose/$APP/files/volumes/db
DATA_DIR=$BASE/data; BACKUP_DIR=$BASE/data.bak.pg15; MIGRATION_DIR=$BASE/data_migration
WORK=${WORK:-/root/pg17-upgrade}; STAGING=$WORK/staging
PGPASS=${POSTGRES_PASSWORD:?POSTGRES_PASSWORD required in the environment}
PG15_UID=${PG15_UID:-105}; PG15_GID=${PG15_GID:-106}
DB_CONFIG_VOL=$(docker volume ls --format '{{.Name}}' | grep -E "^${APP}_db-config$" || true)
info(){ printf '\n==> %s\n' "$*"; }
phase=${1:?phase: build|upgrade|post}
mkdir -p "$STAGING/scripts"; chmod 777 "$STAGING"
for s in initiate.sh complete.sh common.sh pgsodium_getkey.sh check.sh prepare.sh; do
  [ -f "$STAGING/scripts/$s" ] || curl -fsSL "https://raw.githubusercontent.com/supabase/postgres/${SCRIPTS_REF}/ansible/files/admin_api_scripts/pg_upgrade_scripts/$s" -o "$STAGING/scripts/$s"
done

if [ "$phase" = build ]; then
  info "Building upgrade tarball from $UPGRADE_IMAGE"
  docker pull -q "$UPGRADE_IMAGE" >/dev/null; docker pull -q "$TARGET_IMAGE" >/dev/null
  docker run --rm --user root --entrypoint bash -v "$STAGING:/export" "$UPGRADE_IMAGE" -c '
    set -euo pipefail
    mkdir -p /export/17/bin /export/17/lib /export/17/share
    BIN_DIR=$(dirname $(readlink -f /usr/lib/postgresql/bin/postgres))
    for f in "$BIN_DIR"/*; do
      name=$(basename "$f"); case "$name" in .*-wrapped) continue ;; esac
      if [ -x "$f" ] && file -b "$f" | grep -q "ELF .* executable"; then cp "$f" /export/17/bin/"$name"
      else wrapped=$(grep -o "/nix/store/[^ \"]*-wrapped" "$f" 2>/dev/null | head -n 1 || true)
        if [ -n "$wrapped" ] && [ -f "$wrapped" ]; then cp "$wrapped" /export/17/bin/"$name"; else cp "$f" /export/17/bin/"$name"; fi; fi
    done
    PKGLIBDIR=$(pg_config --pkglibdir); LIBDIR=$(pg_config --libdir)
    cp -Lf "$PKGLIBDIR"/*.so /export/17/lib/ || true; cp -Lf "$LIBDIR"/*.so* /export/17/lib/ || true
    cp -Lf /nix/var/nix/profiles/default/lib/*.so* /export/17/lib/ || true
    mkdir -p /export/17/share/postgresql; rm -f /usr/share/postgresql/timezonesets/timezonesets 2>/dev/null || true
    mkdir -p /export/17/share/postgresql/{extension,timezonesets,tsearch_data} /export/17/share/postgresql/extension/{functions,procedures,tables,types}
    cp -rL /usr/share/postgresql/* /export/17/share/postgresql/ || true
    SHAREDIR=$(pg_config --sharedir); cp "$SHAREDIR"/extension/*.control /export/17/lib/ || true; cp "$SHAREDIR"/extension/*.sql /export/17/lib/ || true
    [ -f /export/17/bin/postgres ] || { echo "bin/postgres missing"; exit 1; }
    [ -f /export/17/share/postgresql/timezonesets/Default ] || { echo "timezonesets missing"; exit 1; }
    cd /export && tar czf pg_upgrade_bin.tar.gz 17/ && rm -rf /export/17 && du -sh /export/pg_upgrade_bin.tar.gz'
  info "tarball ready: $STAGING/pg_upgrade_bin.tar.gz"

elif [ "$phase" = upgrade ]; then
  [ -f "$STAGING/pg_upgrade_bin.tar.gz" ] || { echo "no tarball; run build first"; exit 1; }
  [ -z "$(docker ps -q --filter name="$PREFIX")" ] || { echo "stack still running; stop it in Dokploy first"; exit 1; }
  [ "$(cat "$DATA_DIR/PG_VERSION")" = 15 ] || { echo "data dir is not PG15"; exit 1; }
  docker rm -f supabase-pg-upgrade supabase-pg-complete >/dev/null 2>&1 || true
  info "Fixing data dir ownership for the PG15 helper (uid $PG15_UID)"; rm -f "$DATA_DIR/postmaster.pid"; chown -R "$PG15_UID:$PG15_GID" "$DATA_DIR"
  if [ -n "$DB_CONFIG_VOL" ]; then CONF_MOUNT="$DB_CONFIG_VOL"; else CONF_MOUNT="$BASE/config"; fi
  info "Backing up pgsodium key from $CONF_MOUNT"; docker run --rm -v "$CONF_MOUNT:/src:ro" -v "$BASE:/dst" alpine cp /src/pgsodium_root.key /dst/pgsodium_root.key.bak.pg15
  rm -rf "$MIGRATION_DIR"; mkdir -p "$MIGRATION_DIR"; chmod 777 "$MIGRATION_DIR"
  info "Starting upgrade container ($CURRENT_IMAGE)"
  docker run -d --name supabase-pg-upgrade --entrypoint sleep -v "$DATA_DIR:/mnt/host-pgdata" -v "$MIGRATION_DIR:/mnt/host-migration" -v "$CONF_MOUNT:/etc/postgresql-custom" -v "$STAGING:/tmp/staging:ro" -e PGPASSWORD="$PGPASS" "$CURRENT_IMAGE" infinity >/dev/null
  docker exec supabase-pg-upgrade bash -c '
    rm -rf /var/lib/postgresql/data; ln -s /mnt/host-pgdata /var/lib/postgresql/data; ln -s /mnt/host-migration /data_migration
    mkdir -p /tmp/persistent /tmp/upgrade /tmp/pg_upgrade
    cp /tmp/staging/pg_upgrade_bin.tar.gz /tmp/persistent/; cp /tmp/staging/scripts/*.sh /tmp/upgrade/; chmod +x /tmp/upgrade/*.sh
    sed -i "s/pg_ctl start -o/pg_ctl restart -o/g" /tmp/upgrade/common.sh
    sed -i "s|PGSHARENEW=\"\$PG_UPGRADE_BIN_DIR/share\"|PGSHARENEW=\"\$PG_UPGRADE_BIN_DIR/share/postgresql\"|" /tmp/upgrade/initiate.sh'
  info "Starting Postgres 15 inside the helper (recovery can take a couple of minutes)"
  docker exec supabase-pg-upgrade bash -c 'su postgres -c "pg_ctl start -o \"-c config_file=/etc/postgresql/postgresql.conf\" -l /tmp/postgres.log"'
  for i in $(seq 1 120); do docker exec supabase-pg-upgrade pg_isready -U postgres -h localhost >/dev/null 2>&1 && break; sleep 2; done
  docker exec supabase-pg-upgrade pg_isready -U postgres -h localhost || { docker exec supabase-pg-upgrade tail -20 /tmp/postgres.log; exit 1; }
  info "Running initiate.sh (pg_upgrade 15 -> 17)"
  docker exec -e IS_CI=true -e PG_MAJOR_VERSION=17 -e PGPASSWORD="$PGPASS" -e LD_LIBRARY_PATH=/tmp/pg_upgrade_bin/17/lib -e NIX_PGLIBDIR=/tmp/pg_upgrade_bin/17/lib supabase-pg-upgrade /tmp/upgrade/initiate.sh 17
  docker rm -f supabase-pg-upgrade >/dev/null
  info "Running complete.sh in $UPGRADE_IMAGE"
  docker run -d --name supabase-pg-complete --entrypoint sleep -v "$MIGRATION_DIR:/mnt/host-migration" -v "$CONF_MOUNT:/etc/postgresql-custom" -v "$STAGING:/tmp/staging:ro" -e PGPASSWORD="$PGPASS" "$UPGRADE_IMAGE" infinity >/dev/null
  docker exec supabase-pg-complete bash -c '
    ln -s /mnt/host-migration /data_migration; rm -rf /var/lib/postgresql/data
    chown -R postgres:postgres /etc/postgresql-custom/; mkdir -p /etc/postgresql-custom/conf.d /tmp/upgrade
    cp /tmp/staging/scripts/*.sh /tmp/upgrade/; chmod +x /tmp/upgrade/*.sh
    sed -i "s|BINDIR=\"/tmp/pg_upgrade_bin/\$PG_MAJOR_VERSION/bin\"|BINDIR=\$(pg_config --bindir)|g" /tmp/upgrade/common.sh'
  docker exec -e IS_CI=true -e PG_MAJOR_VERSION=17 -e PGPASSWORD="$PGPASS" supabase-pg-complete /tmp/upgrade/complete.sh || true
  status=$(docker exec supabase-pg-complete cat /tmp/pg-upgrade-status 2>/dev/null || echo unknown)
  if [ "$status" != complete ]; then docker exec supabase-pg-complete cat /tmp/postgres.log 2>/dev/null || true; docker rm -f supabase-pg-complete; echo "complete.sh failed: $status (PG15 data untouched)"; exit 1; fi
  docker rm -f supabase-pg-complete >/dev/null
  info "Swapping data directories ($BACKUP_DIR keeps the PG15 copy)"; mv "$DATA_DIR" "$BACKUP_DIR"; mv "$MIGRATION_DIR/pgdata" "$DATA_DIR"; rm -rf "$MIGRATION_DIR"
  info "Preparing files/volumes/db/config for the current template"
  docker run --rm -v "$CONF_MOUNT:/vol" "$TARGET_IMAGE" sh -c 'mkdir -p /vol/conf.d; chown -R postgres:postgres /vol/'
  mkdir -p "$BASE/config"; [ "$CONF_MOUNT" = "$BASE/config" ] || docker run --rm -v "$CONF_MOUNT:/src:ro" -v "$BASE/config:/dst" alpine sh -c 'cp -a /src/. /dst/'
  echo "PG_VERSION is now $(cat "$DATA_DIR/PG_VERSION"). Deploy the current template in Dokploy, then run the 'post' phase."

elif [ "$phase" = post ]; then
  DB=${PREFIX}-db
  run(){ docker exec -i -e PGPASSWORD="$PGPASS" "$DB" psql -h localhost -U supabase_admin -v ON_ERROR_STOP=1 "$@"; }
  info "Postgres 17 migrations"
  for db in postgres template1 _supabase; do docker exec -i -e PGPASSWORD="$PGPASS" "$DB" psql -h localhost -U supabase_admin -d "$db" -c "ALTER DATABASE \"$db\" REFRESH COLLATION VERSION;" || true; done
  run -d postgres -c "DO \$\$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='supabase_etl_admin') THEN CREATE USER supabase_etl_admin WITH LOGIN REPLICATION; GRANT pg_read_all_data TO supabase_etl_admin; GRANT CREATE ON DATABASE postgres TO supabase_etl_admin; END IF; END \$\$;" || true
  for m in 20250710151649_supabase_read_only_user_default_transaction_read_only.sql 20251001204436_predefined_role_grants.sql 20251105172723_grant_pg_reload_conf_to_postgres.sql 20251121132723_correct_search_path_pgbouncer.sql 20260211120934_supabase_privileged_role.sql 20260413000000_fix-authenticator-session-preload-libraries.sql 20260421000001_rescope_pg_graphql_access_trigger.sql; do
    echo "  migration $m"; docker exec -i -e PGPASSWORD="$PGPASS" "$DB" psql -h localhost -U supabase_admin -d postgres -v ON_ERROR_STOP=1 -f "/docker-entrypoint-initdb.d/migrations/$m" || echo "  (non-fatal) $m failed"; done
  info "Reconciling extension versions and analyzing"
  run -d postgres -c "DO \$\$ DECLARE r record; BEGIN FOR r IN SELECT extname FROM pg_extension LOOP BEGIN EXECUTE format('ALTER EXTENSION %I UPDATE', r.extname); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'skipped %: %', r.extname, SQLERRM; END; END LOOP; END \$\$;" || true
  for db in postgres _supabase; do run -d "$db" -qc "analyze" || true; done
  run -d postgres -A -t -c "select version()"; run -d postgres -c "SELECT extname, extversion FROM pg_extension ORDER BY 1;"
fi
