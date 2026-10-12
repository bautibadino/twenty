# Deploy de Twenty en el VPS

Configuración de producción del CRM. Vive en el VPS en `/opt/twenty` — este
directorio es la copia versionada de esos archivos, para no depender del disco
del server.

Contexto: el CRM comparte VPS con la plataforma WooCommerce headless. Stack
propio (Postgres, Redis, server, worker); lo único compartido es **Traefik**, vía
la red externa `wcp_edge`.

## Prerrequisitos

- **Traefik del stack WooCommerce corriendo**, con la red `wcp_edge`. El
  `certResolver: letsencrypt` está declarado a nivel *entrypoint* (`websecure`)
  en su `traefik.prod.yml`, así que los routers **no** necesitan declarar
  `certresolver` en sus labels — alcanza con `tls=true`.
- **DNS wildcard** `*.<dominio>` → IP del VPS. Cada workspace nuevo estrena
  subdominio, y el challenge es HTTP-01 por host: sin wildcard, el workspace
  levanta pero se queda sin certificado.
- Imagen `ghcr.io/bautibadino/twenty-fork` (privada), construida por GitHub
  Actions. El job de deploy le presta al server su token temporal para el pull. En el server solo se hace `docker pull`; ver "Deploy automatizado".
- Usuario de deploy en el server, miembro del grupo `docker`, con escritura en
  `/opt/twenty`.

## Deploy desde cero

```bash
# 1. Imagen (target `twenty` = backend + frontend en un solo contenedor)
docker pull ghcr.io/bautibadino/twenty-fork:latest
docker tag ghcr.io/bautibadino/twenty-fork:latest twenty-fork:latest

# 2. Config
cd /opt/twenty
cp <este-repo>/deploy/vps/docker-compose.yml .
cp <este-repo>/deploy/vps/.env.example .env   # y completar

# 3. Schema inicial + upgrade (instancia y workspaces)
docker compose up -d db redis
docker compose run --rm server node dist/database/scripts/setup-db.js
docker compose run --rm server node dist/command/command upgrade

# 4. Arriba
docker compose up -d
```

## Deploy automatizado

El workflow `.github/workflows/fork-upstream-sync.yaml` mantiene el fork al día
con los releases de upstream (`twentyhq/twenty`, tags `twenty/vX.Y.Z`) y despliega
sin intervención:

1. **detect** (diario, 07:00 hora Argentina): busca el último tag estable de
   upstream. Si ya está en `main`, termina en segundos.
2. **merge**: mergea el tag con `deploy/automation/sync-upstream.sh`. Si hay
   conflictos o falla la verificación (build y typecheck), corre un agente de
   Claude con las reglas de `deploy/automation/merge-policy.md` y vuelve a
   verificar. Si sigue fallando, no se mergea ni se despliega nada: se abre el
   issue `Upstream sync <tag> needs attention` y el trabajo queda en la rama
   `sync/upstream-<versión>`.
3. **build**: construye la imagen en GitHub Actions y la publica en
   `ghcr.io/bautibadino/twenty-fork` con los tags `<sha>` y `latest`.
4. **deploy**: copia el compose al server y ejecuta `deploy/vps/deploy.sh` por
   SSH (sin checkout en el server). Después consulta el healthcheck público.
   Si falla, abre el issue `Deploy <sha> failed`.

Los PR propios que se mergean a `main` también pasan por build + deploy (sin
detect ni merge). El workflow `fork-ci.yaml` corre un chequeo liviano en cada PR.

El fork **no** lleva los workflows de upstream: `.github/workflows/` contiene solo
archivos propios, y en cada merge se conserva nuestro lado.

### Secrets y variables del repo

| Nombre | Tipo | Uso |
|---|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` | secret | Agente que resuelve conflictos |
| `VPS_HOST` | secret | Host o IP del VPS |
| `VPS_USER` | secret | Usuario de deploy |
| `VPS_SSH_KEY` | secret | Clave privada ed25519 del usuario de deploy |
| `VPS_KNOWN_HOSTS` | secret | Línea de host key fijada (`ssh-keyscan -t ed25519 <host>`). Si está vacío el deploy falla: nunca se desactiva la verificación de host |
| `DEPLOY_HEALTHCHECK_URL` | variable | Opcional. Por defecto `https://app.pymeinteligente.online/healthz` |

### Qué hace `deploy.sh`

Corre en el server como el usuario de deploy y deja el log en
`/opt/twenty/deploy.log`:

1. Verifica docker, `docker-compose.yml`, `.env` y al menos 8 GB libres.
2. `docker pull` de la imagen nueva, todavía sin cortar el servicio.
3. **Detiene `server` y `worker`.** Desde acá hasta el paso 7 el CRM está caído:
   el código viejo no puede escribir mientras se toma el dump ni mientras se
   migra el schema, porque lo escrito después del dump se perdería al restaurar.
4. **Dump previo** `pg_dump -Fc` a `/opt/twenty/backups/predeploy-<fecha>.dump`,
   verificado con `pg_restore --list`. Si falla, vuelve a levantar la versión
   actual y aborta sin haber cambiado nada.
5. Deja la imagen en uso como `twenty-fork:previous` y etiqueta la nueva como
   `twenty-fork:latest`.
6. Corre el upgrade con la imagen **nueva** (`cache:flush`, `upgrade`,
   `cache:flush`). Si falla, restaura el tag anterior y levanta la versión
   vieja. **No restaura la base**: puede haber quedado parcialmente migrada.
7. `docker compose up -d server worker` y espera hasta 5 minutos a que
   `twenty_server` esté `healthy`. Si no llega, vuelve a la imagen anterior.
8. Limpia imágenes viejas y dumps `predeploy-*` de más de 14 días.

### Ejecutar a mano

En GitHub: Actions > "Fork upstream sync" > Run workflow. Parámetros:

- `upstream_tag`: tag a mergear (por ejemplo `twenty/v2.46.0`). Vacío = el último.
- `deploy_only`: no mergea; reconstruye y despliega el `main` actual.

O con la CLI: `gh workflow run fork-upstream-sync.yaml -f deploy_only=true`.

### Volver atrás a mano

Solo la imagen (el schema no cambió, o la versión anterior lo tolera):

```bash
cd /opt/twenty
docker tag twenty-fork:previous twenty-fork:latest
docker compose up -d --force-recreate server worker
```

Si el deploy corrió migraciones de schema, volver a la imagen anterior **no**
alcanza: hay que restaurar también el dump pre-deploy.

### Restaurar el dump pre-deploy

Es la única vía de vuelta después de un upgrade de schema. Se pierden los datos
escritos desde que se tomó el dump.

```bash
cd /opt/twenty
ls -lt backups/predeploy-*.dump | head -3          # elegir el dump
docker compose stop server worker
docker exec -i twenty_db pg_restore -U twenty -d default --clean --if-exists \
  < backups/predeploy-<STAMP>.dump
docker tag twenty-fork:previous twenty-fork:latest
docker compose up -d server worker
```

(`twenty` y `default` son los valores de `PG_DATABASE_USER` y `PG_DATABASE_NAME`
del `.env`.)

## Operación

```bash
# Logs / estado
docker compose logs -f server
docker inspect twenty_server --format '{{.State.Health.Status}}'
tail -f /opt/twenty/deploy.log
```

**Las migraciones no corren solas**: el compose fija `DISABLE_DB_MIGRATIONS=true`
en server y worker. `deploy.sh` las corre antes de levantar la imagen nueva. A
mano (por ejemplo con `rebuild.sh`, el fallback manual que construye en el
server):

```bash
docker compose run --rm --no-deps -e DISABLE_CRON_JOBS_REGISTRATION=true server \
  node dist/command/command upgrade
```

`upgrade` es el único comando necesario: ejecuta en orden los comandos de
instancia rápidos, los lentos y los de workspace.

## Storage

`STORAGE_TYPE=local`: los archivos (adjuntos, avatares, logos, assets de
serverless functions) viven en el volumen `twenty_twenty-storage`, montado en
server **y** worker — ambos leen y escriben ahí, así que el volumen tiene que ser
el mismo.

Hasta el 2026-07-27 esto apuntaba a un bucket S3 en Railway. Se migró a local
(20 objetos, 2.2 MB) para poder dar de baja Railway; el detalle está en el commit
que agregó este directorio.

## Backups

Dos volúmenes a cuidar: `twenty_twenty-db` (la base) y `twenty_twenty-storage`
(los archivos). El Auto Backup de Contabo cubre el disco entero del VPS, pero es
un backup de infraestructura: restaura la máquina completa, y con ella arrastra
todo lo demás que vive en el VPS al mismo punto en el tiempo.

`backup-twenty.sh` cubre el otro lado: dump lógico diario a `/opt/twenty/backups`,
retención de 30 días, con verificación del dump. Instalación:

```bash
chmod +x /opt/twenty/src/deploy/vps/backup-twenty.sh
mkdir -p /opt/twenty/backups
(crontab -l 2>/dev/null | grep -v backup-twenty; \
 echo "15 3 * * * /opt/twenty/src/deploy/vps/backup-twenty.sh >> /opt/twenty/backups/backup.log 2>&1") | crontab -
```

Los dos son complementarios: el snapshot te salva de perder el disco, el dump te
deja volver atrás solo el CRM.

### Restaurar

```bash
# Base completa (borra y recrea el contenido actual)
docker exec -i twenty_db pg_restore -U twenty -d default --clean --if-exists \
  < /opt/twenty/backups/twenty-db-<STAMP>.dump

# Solo el schema de un workspace
docker exec -i twenty_db pg_restore -U twenty -d default --schema=workspace_<id> \
  < /opt/twenty/backups/twenty-db-<STAMP>.dump

# Archivos
docker run --rm -v twenty_twenty-storage:/data -v /opt/twenty/backups:/in alpine \
  tar xzf /in/twenty-storage-<STAMP>.tar.gz -C /data
```

Después de restaurar archivos, corregir el dueño (el contenedor corre como uid 1000):
`docker exec -u 0 twenty_server chown -R node:node /app/packages/twenty-server/.local-storage`

## Historia

El CRM corrió primero en Railway. El 2026-07-01 se migró al VPS restaurando
`railway.dump` (queda en `/opt/twenty/migration/`, **no** se versiona: son datos
de producción y este repo es público). El 2026-07-27 se cortó la última
dependencia con Railway moviendo el storage al volumen local.
