# Upgrading an Existing Supabase Deployment (and removing the JWT secret from the database)

This guide is for deployments that were created from an **older version of these templates** and are running on Dokploy. It upgrades them in place to the current image set (upstream self-hosted v0.8.1, September 2026) and removes the JWT signing secret from Postgres, **without dumping/restoring the database and without losing users, storage objects, or sessions**.

Repeat the whole procedure once per deployment. Each deployment has its own `CONTAINER_PREFIX`, referred to as `<PREFIX>` below (for example `my-supabase` or `baseloop-supabase`).

## What the upgrade does

- **Security fix.** Old templates stored `JWT_SECRET` in Postgres as the database setting `app.settings.jwt_secret` and re-injected it on every PostgREST request. Any database role, including `anon` calling a SQL function through the REST API, could read it and forge `service_role` tokens ([supabase/supabase#43513](https://github.com/supabase/supabase/issues/43513)). The new compose never writes it, and a one-shot `db-jwt-reset` job removes it from your existing database on every deploy.
- **Image bump** to Postgres 17.6.1.136, Kong 3.9.3, GoTrue v2.196.0, PostgREST v14.17, Realtime v2.134.10, Storage v1.74.0, imgproxy v3.31.4, postgres-meta v0.99.0, Studio 2026.09.07, Logflare 1.50.10, edge-runtime v1.76.2, Supavisor 2.9.12.
- **Config changes** required by those versions (Kong routes, Vector config, renamed env vars). The env changes are listed in step 3.

Postgres stays on the 17.6 line, so the existing data directory is reused as-is. Auth, Storage, Realtime, Logflare and Supavisor apply their own **forward-only** schema migrations on first boot of the new images; that is normal and takes under a minute.

Expected downtime: 2 to 5 minutes while containers are recreated. User sessions survive because `JWT_SECRET` does not change (unless you choose to rotate it in step 6).

> **Still on Postgres 15?** If step 1 shows `supabase/postgres:15.x`, do the major upgrade as part of step 4 with [`utils/upgrade-pg17-dokploy.sh`](utils/upgrade-pg17-dokploy.sh) (upstream's pg_upgrade procedure adapted to the Dokploy layout): run its `build` phase while the stack is up, stop the stack, run `upgrade`, deploy the new compose, then run `post`. It keeps the Postgres 15 directory as `data.bak.pg15` for rollback. **Never deploy the 17.x image on a 15 data directory first**: it refuses to start, but its entrypoint chowns the data directory to a different uid and leaves a pid file that blocks the upgrade helper (the script repairs both, but avoid it).

---

## Step 1: Preflight (SSH to the server)

Check what is running and which Postgres major version you are on:

```bash
docker ps --filter "name=<PREFIX>" --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
```

Confirm the bug is present (expect `1`; the fix will make this `0`):

```bash
docker exec <PREFIX>-db psql -U supabase_admin -d postgres -tAc \
  "select count(*) from pg_db_role_setting, unnest(setconfig) c where c like 'app.settings.jwt_secret=%'"
```

Check whether Studio created objects as `supabase_admin` (decides what you do in step 5; `0` means nothing to do):

```bash
docker exec <PREFIX>-db psql -U supabase_admin -d postgres -tAc \
  "select count(*) from pg_class where relnamespace='public'::regnamespace and relowner='supabase_admin'::regrole"
```

Copy the current environment from the Dokploy **Environment** tab into a file on your machine. You need the existing secrets in step 3 and the whole thing for a rollback.

## Step 2: Back up

Take both backups. The logical dump can be restored anywhere; the cold copy is the fast, exact rollback.

**2a. Logical dump (stack keeps running):**

```bash
docker exec <PREFIX>-db pg_dumpall -U supabase_admin --clean --if-exists \
  > /root/<PREFIX>-pre-upgrade-$(date +%F).sql
ls -lh /root/<PREFIX>-pre-upgrade-*.sql
```

**2b. Cold copy of the data directory.** In Dokploy open the compose service and click **Stop**. Then on the server:

```bash
# Dokploy keeps the compose's persistent data in .../files next to the code dir
COMPOSE_DIR=/etc/dokploy/compose/<compose-name>
sudo tar -C "$COMPOSE_DIR" -czf /root/<PREFIX>-files-$(date +%F).tgz files
tar -tzf /root/<PREFIX>-files-*.tgz | grep -m1 'files/volumes/db/data/PG_VERSION' && echo "backup contains the database"
```

`<compose-name>` is the directory under `/etc/dokploy/compose/` that holds this service (`ls /etc/dokploy/compose/`). The `files/` directory contains `volumes/db/data` (Postgres), `volumes/db/config` (pgsodium key, TLS cert), `volumes/storage` (uploaded objects) and `volumes/functions`.

Leave the service stopped; the deploy in step 4 starts it again. If you take a Hetzner snapshot as well, do it now while it is stopped.

## Step 3: Update the environment variables in Dokploy

Open the **Environment** tab and make these edits. **Do not** change anything else. In particular keep `CONTAINER_PREFIX`, `POSTGRES_PASSWORD`, `JWT_SECRET`, `ANON_KEY`, `SERVICE_ROLE_KEY`, `SECRET_KEY_BASE`, `VAULT_ENC_KEY`, `REALTIME_DB_ENC_KEY`, `PG_META_CRYPTO_KEY`, `POOLER_TENANT_ID`, `DASHBOARD_*` and all port variables exactly as they are: they decrypt or address data that already exists.

| Variable | Change | Why |
|----------|--------|-----|
| `API_EXTERNAL_URL` | Append `/auth/v1`, e.g. `https://sb.example.com` becomes `https://sb.example.com/auth/v1` | Upstream v0.7.0 convention. It becomes the `iss` claim of new tokens and the base for OAuth callbacks. Clients that validate `iss`, and OAuth provider redirect URIs, must be updated to match. |
| `S3_PROTOCOL_ACCESS_KEY_ID` | Add, value from `openssl rand -hex 16` | New Storage version serves an S3-compatible endpoint at `/storage/v1/s3`; these are its credentials. |
| `S3_PROTOCOL_ACCESS_KEY_SECRET` | Add, value from `openssl rand -hex 32` | Same. |
| `IMGPROXY_ENABLE_WEBP_DETECTION` | Rename to `IMGPROXY_AUTO_WEBP` (keep the value) | Upstream renamed it. |
| `LOGFLARE_LOGGER_BACKEND_API_KEY` | Delete | No longer used; `LOGFLARE_PUBLIC_ACCESS_TOKEN` and `LOGFLARE_PRIVATE_ACCESS_TOKEN` stay. |
| `PGRST_DB_SCHEMAS` | Set to `public,graphql_public` unless your app reads `storage.objects` through the REST API | `storage` is a protected schema; upstream stopped exposing it. Leave the old value if you depend on it. |
| `STUDIO_DB_USER` | Add. Use `postgres` if the preflight count was `0`, otherwise start with `supabase_admin` | Studio and postgres-meta now run SQL as the non-superuser `postgres`. Objects that Studio created as `supabase_admin` cannot be altered by `postgres` until you reassign them (step 5). `supabase_admin` keeps the old behaviour. |
| `SUPABASE_PUBLISHABLE_KEY`, `SUPABASE_SECRET_KEY`, `ANON_KEY_ASYMMETRIC`, `SERVICE_ROLE_KEY_ASYMMETRIC` | Optional, add empty | New-style API keys; blank keeps the current `ANON_KEY` / `SERVICE_ROLE_KEY` behaviour. |

Compare against the current [`supabase.env`](supabase.env) or [`optimized-supabase.env`](optimized-supabase.env) if you want to pick up the new tuning knobs (`PGRST_DB_MAX_ROWS`, `PGRST_DB_EXTRA_SEARCH_PATH`); they have defaults in the compose and are optional.

Save the environment.

## Step 4: Replace the compose file and deploy

1. In the **Compose** tab, select all and replace with the full contents of the same variant you deployed originally: [`supabase-docker-compose.yml`](supabase-docker-compose.yml) or [`optimized-supabase-docker-compose.yml`](optimized-supabase-docker-compose.yml). Save.
2. Click **Deploy**.

Because `CONTAINER_PREFIX` is unchanged, the containers get the same names and the same `../files/volumes/...` bind mounts, so the new images start on top of your existing data.

Watch the deploy log. Three one-shot jobs run and exit `0`:

| Job | Expected log |
|-----|--------------|
| `<PREFIX>-db-init` | `Config directory already populated, skipping.` then either `TLS cert already present, skipping.` (standard variant) or `Generating self-signed TLS cert for Postgres...` (optimized variant, first time only; it enables `ssl=on` and `sslmode=require` for direct connections, plaintext still works) |
| `<PREFIX>-db-jwt-reset` | `ALTER DATABASE` twice, then `OK: app.settings.jwt_secret is not stored in the database` |
| `<PREFIX>-functions-init` | `... already exists, skipping.` for each seeded file |

Then the long-running containers come up. Auth, Storage, Realtime, Logflare and Supavisor log their migrations on first start. Allow 2 to 3 minutes before judging health; the healthchecks have start periods.

## Step 5: Verify

All 13 long-running containers healthy:

```bash
docker ps --filter "name=<PREFIX>" --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
```

The secret is gone from the database (expect `0` and an empty line):

```bash
docker logs <PREFIX>-db-jwt-reset --tail 1
docker exec <PREFIX>-db psql -U supabase_admin -d postgres -tAc \
  "select count(*) from pg_db_role_setting, unnest(setconfig) c where c like 'app.settings.jwt_secret=%'"
docker exec <PREFIX>-db psql -U supabase_admin -d postgres -tAc \
  "select current_setting('app.settings.jwt_secret', true)"
```

If you want to prove it through the API path the attacker would use, run this once and delete the function afterwards:

```bash
docker exec <PREFIX>-db psql -U supabase_admin -d postgres -c \
  "create function public.leak_check() returns text language sql as \$\$ select coalesce(current_setting('app.settings.jwt_secret', true), 'not exposed') \$\$; grant execute on function public.leak_check() to anon;" \
  -c "notify pgrst, 'reload schema'"
curl -s https://<your-domain>/rest/v1/rpc/leak_check -H "apikey: <ANON_KEY>" -H "Authorization: Bearer <ANON_KEY>"
# expect: "not exposed"
docker exec <PREFIX>-db psql -U supabase_admin -d postgres -c "drop function public.leak_check()"
```

Application checks:

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://<your-domain>/auth/v1/health -H "apikey: <ANON_KEY>"          # 200
curl -s https://<your-domain>/rest/v1/<a-table>?select=*&limit=1 -H "apikey: <ANON_KEY>" -H "Authorization: Bearer <ANON_KEY>"
curl -s -o /dev/null -w '%{http_code}\n' https://<your-domain>/storage/v1/object/public/<bucket>/<object>   # 200 for a public object
```

Then, in the browser: log into Studio, open an existing table, open **Storage** and check a bucket, open **Logs** and confirm entries arrive, and check that your app's Realtime subscriptions still receive changes.

**Studio role.** In the Studio SQL editor run `select current_user;`. If it returns `postgres` and you can edit your tables, you are done. If you get `must be owner of relation ...` errors, the objects are still owned by `supabase_admin`: either run the reassignment SQL from the "Upgrading an existing deployment" section of [`README.md`](README.md#upgrading-an-existing-deployment) once (as `supabase_admin`) and keep `STUDIO_DB_USER=postgres`, or set `STUDIO_DB_USER=supabase_admin` and redeploy.

**GraphQL.** Databases that already had `pg_graphql` keep it. Check with `select extname from pg_extension where extname='pg_graphql';`. If it is missing and you use `/graphql/v1`, run `create extension pg_graphql;`.

**Direct database clients** (Prisma migrations, psql) keep working unchanged: same host port, same password. TLS is now available on the direct port, so you can add `?sslmode=require`.

## Step 6: Decide whether to rotate the JWT secret

The fix stops the secret from being readable **from now on**. It cannot tell you whether it was already read. Rotate if any of these apply, or if in doubt:

- anyone other than you could run SQL against the database (shared credentials, a leaked connection string, a third-party tool with a database user),
- you expose RPC functions that untrusted users can call and that could have wrapped `current_setting(...)`,
- the deployment had SQL injection or similar issues in the past.

**Consequences of rotating:** every user session (access and refresh tokens) becomes invalid and users must sign in again; `ANON_KEY` and `SERVICE_ROLE_KEY` change, so every app, mobile build, edge function secret and CI variable that holds them must be updated at the same time. Studio login (`DASHBOARD_*`) and the database password are not affected.

Steps:

1. Generate a new `JWT_SECRET` (`openssl rand -hex 20`) and sign a new `ANON_KEY` and `SERVICE_ROLE_KEY` with it (see [`DEPLOY-GUIDE.md`](DEPLOY-GUIDE.md#generate-jwt-keys-anon_key-and-service_role_key)).
2. Replace the three values in the Dokploy **Environment** tab and **Deploy**. Every service reads the secret from its environment: Kong, GoTrue, PostgREST, Storage, Supavisor, edge functions, Studio. Realtime deletes and re-creates its tenant from `API_JWT_SECRET` on every boot, so it picks the new secret up too. **No SQL is needed.** Older forum advice to run `ALTER DATABASE postgres SET "app.settings.jwt_secret"` is exactly the bug this guide removes; do not do it.
3. Roll the new `ANON_KEY` / `SERVICE_ROLE_KEY` out to your applications.

If you have your own SQL functions that used `current_setting('app.settings.jwt_secret')`, store the secret in [Vault](https://supabase.com/docs/guides/database/vault) instead: `select vault.create_secret('<new secret>', 'jwt_secret');` and read `vault.decrypted_secrets` inside a `security definer` function that only trusted roles can execute.

## Step 7: Optional follow-ups

- **OAuth / social login.** Update each provider's redirect URI to `https://<your-domain>/auth/v1/callback` (it was already the working URL through Kong; the change in `API_EXTERNAL_URL` just makes GoTrue advertise the correct one).
- **Edge functions main worker.** `functions-init` never overwrites existing files, so your deployment still runs the old `main/index.ts`. It works with the new runtime. To adopt the upstream worker (hybrid HS256/ES256 verification, shared `deno.jsonc` import map), delete `files/volumes/functions/main/index.ts` on the server and redeploy; keep any customisations you made.
- **Kernel tuning** for the optimized variant is unchanged; see [`kernel-tuning-notes.md`](kernel-tuning-notes.md).

## Rollback

The JWT fix itself never needs rolling back: the old compose does not re-add the setting (init scripts only run on an empty data directory) and no bundled service reads it.

If the upgrade as a whole must be reverted, restore the cold copy. Do **not** just paste the old compose over a database the new images already started: Auth, Storage, Realtime, Logflare and Supavisor applied forward-only schema migrations, and older versions are not guaranteed to run against the newer schema.

1. In Dokploy, **Stop** the compose service.
2. On the server:
   ```bash
   COMPOSE_DIR=/etc/dokploy/compose/<compose-name>
   sudo mv "$COMPOSE_DIR/files" "$COMPOSE_DIR/files.failed-upgrade"
   sudo tar -C "$COMPOSE_DIR" -xzf /root/<PREFIX>-files-<date>.tgz
   ```
3. Paste the previous compose file and the previous environment (the copy from step 1) back into Dokploy and **Deploy**.
4. Once everything is healthy, delete `files.failed-upgrade`.

Anything written between the backup and the rollback (new users, uploads) is lost; that is the window between step 2b and the moment you decide to roll back, so verify promptly after deploying.

## Common problems

| Symptom | Cause / fix |
|---------|-------------|
| `db-jwt-reset` exits non-zero with `permission denied` or `password authentication failed` | `POSTGRES_PASSWORD` in the env does not match the database. Restore the original value. |
| `kong` restarts with a config error mentioning `expression` or `router_flavor` | The compose was not replaced completely; `KONG_ROUTER_FLAVOR: expressions` and the `kong_entrypoint` config must be present. Paste the whole file again. |
| `storage` fails to start | `S3_PROTOCOL_ACCESS_KEY_ID` / `S3_PROTOCOL_ACCESS_KEY_SECRET` missing (step 3). |
| `imgproxy` ignores webp | Variable was renamed; set `IMGPROXY_AUTO_WEBP=true`. |
| Studio: `must be owner of relation` | Objects owned by `supabase_admin`; see the Studio role paragraph in step 5. |
| `/graphql/v1` returns `pg_graphql extension is not enabled` | `create extension pg_graphql;` (step 5). |
| `/rest/v1/` (bare root) returns 403 with the anon key | Intended: the OpenAPI root is service-role only now. Table paths are unaffected. |
| `/realtime/v1/api/tenants/...` returns 403 | Intended: blocked at the gateway (upstream security fix). Websocket subscriptions are unaffected. |
| Users logged out after step 6 | Expected after rotating `JWT_SECRET`. |
| Realtime crash-loops with `could not fetch environment variable "METRICS_JWT_SECRET"` | Realtime v2.9x+ requires it. The templates set it; a hand-written compose from before 2026-03 may not. Add `METRICS_JWT_SECRET: ${JWT_SECRET}` to the realtime service. |
| Deploy fails with `pull access denied for minio/mc` (S3/MinIO variants only) | Docker Hub no longer serves the untagged `minio/mc` image. Pin it, e.g. `quay.io/minio/mc:RELEASE.2025-08-13T08-35-41Z`. |
| Vector logs `dns error ... Name does not resolve` or Realtime logs `PromEx ... ETS table` in the first 20 seconds | Boot-time races while Logflare and the Realtime tenant come up. They stop on their own; only investigate if they persist. |
