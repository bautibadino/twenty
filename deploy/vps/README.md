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
- Imagen `twenty-fork:latest` construida en el server (ver más abajo).

## Deploy desde cero

```bash
# 1. Código (el build necesita el repo completo, no solo este directorio)
git clone https://github.com/bautibadino/twenty.git /opt/twenty/src

# 2. Imagen — target `twenty` = backend + frontend en un solo contenedor
cd /opt/twenty/src
docker build --target twenty -f packages/twenty-docker/twenty/Dockerfile -t twenty-fork:latest . 2>&1 | tee /opt/twenty/build.log

# 3. Config
cd /opt/twenty
cp <este-repo>/deploy/vps/docker-compose.yml .
cp <este-repo>/deploy/vps/.env.example .env   # y completar

# 4. Schema inicial + comandos de instancia
docker compose up -d db redis
docker compose run --rm server node dist/database/scripts/setup-db.js
docker compose run --rm server node dist/command/command run-instance-commands --force --include-slow

# 5. Arriba
docker compose up -d
```

## Operación

```bash
# Desplegar cambios de código
cd /opt/twenty/src && git pull
docker build --target twenty -f packages/twenty-docker/twenty/Dockerfile -t twenty-fork:latest .
cd /opt/twenty && docker compose up -d server worker

# Logs / estado
docker compose logs -f server
docker inspect twenty_server --format '{{.State.Health.Status}}'
```

**Las migraciones no corren solas**: el compose fija `DISABLE_DB_MIGRATIONS=true`
en server y worker. Al actualizar la versión de Twenty hay que correrlas a mano
*antes* de levantar la imagen nueva:

```bash
docker compose run --rm server node dist/command/command run-instance-commands --force --include-slow
```

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
