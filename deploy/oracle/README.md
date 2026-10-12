# Deploy de Twenty en la VM Oracle (producción)

Configuración de producción del CRM desde el 2026-08-30. Este directorio es la
copia versionada de lo que corre en la VM Oracle, en `/opt/twenty`. El stack
anterior (Contabo, detenido) está documentado en `deploy/vps/` solo como
referencia de rollback.

## Arquitectura

```
usuario ──HTTPS──▶ Traefik (VPS Contabo, 147.93.183.23)   termina TLS
                        │  http, puerto 3010 del bridge docker (172.18.0.1)
                        ▼
              túnel SSH inverso (twenty-tunnel.service, en la VM Oracle)
              -R 172.18.0.1:3010:127.0.0.1:3000 root@147.93.183.23
                        ▼
VM Oracle (ubuntu@140.84.189.32, Ubuntu 22.04, aarch64, 24 GB RAM)
   127.0.0.1:3000 ─▶ twenty_server_oracle ─▶ twenty_db_oracle (Postgres 16)
                     twenty_worker_oracle     twenty_redis_oracle (Redis 7)
```

Por qué así: la Security List de OCI tiene bloqueados los puertos 80/443, así que
la VM no puede recibir tráfico público ni validar certificados por sí misma.
Traefik sigue en Contabo (donde ya apuntaba el DNS y donde se emiten los
certificados), y la VM se conecta *hacia afuera* con un túnel SSH inverso. Por eso
el server publica **solo** `127.0.0.1:3000`: el túnel reenvía exactamente ese
puerto.

La VM aloja además un bot que no tiene relación con el CRM. Nada fuera de
`/opt/twenty` se toca desde este deploy.

## Dónde vive cada cosa

| Qué | Dónde |
|---|---|
| Directorio del stack | `/opt/twenty` (dueño: `ubuntu`, que usa docker sin sudo) |
| Compose | `/opt/twenty/docker-compose.oracle.yml` (copia de `deploy/oracle/docker-compose.yml`, la sube el workflow) |
| Variables | `/opt/twenty/.env` (real, nunca se versiona; plantilla en `.env.example`) |
| Proyecto compose | `twenty-oracle`; siempre `docker compose -f docker-compose.oracle.yml ...` desde `/opt/twenty` |
| Contenedores | `twenty_db_oracle`, `twenty_redis_oracle`, `twenty_server_oracle`, `twenty_worker_oracle` |
| Volúmenes (datos de producción) | `twenty-oracle_twenty-db-oracle`, `twenty-oracle_twenty-storage-oracle` |
| Imagen local | `twenty-fork:arm64` (actual) y `twenty-fork:arm64-previous` (rollback) |
| Dumps pre-deploy | `/opt/twenty/backups/predeploy-<fecha>.dump` (14 días) |
| Backups diarios | `/opt/twenty/backups/twenty-db-*.dump` y `twenty-storage-*.tar.gz` (30 días) |
| Log del deploy | `/opt/twenty/deploy.log` |
| Túnel | `twenty-tunnel.service` (systemd, en la VM) |
| Rutas y certificados | Contabo: `/opt/woocommerce-platform/traefik/dynamic/twenty-oracle.yml` |

**Los nombres de volumen no se pueden cambiar**: un volumen nuevo arranca vacío y
el CRM parecería haber perdido todos los datos.

Toda la configuración llega por `.env` y la sección `environment:` del compose.
Una variable que no figura ahí no llega al contenedor. No hay `env_file`.

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
3. **build**: construye la imagen **linux/arm64** en un runner ARM nativo
   (`ubuntu-24.04-arm`) y la publica en `ghcr.io/bautibadino/twenty-fork` con los
   tags `<sha>` y `latest`.
4. **deploy**: copia `deploy/oracle/docker-compose.yml` a
   `/opt/twenty/docker-compose.oracle.yml` y ejecuta `deploy/oracle/deploy.sh` por
   SSH (sin checkout en el server). Después consulta el healthcheck público. Si
   falla, abre el issue `Deploy <sha> failed`.

Los PR propios que se mergean a `main` también pasan por build + deploy (sin
detect ni merge). `fork-ci.yaml` corre un chequeo liviano en cada PR. El fork
**no** lleva los workflows de upstream.

`backup-twenty.sh` **no** lo despliega el workflow: se instala a mano (ver
"Backup diario").

### Secrets y variables del repo

| Nombre | Tipo | Uso |
|---|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` | secret | Agente que resuelve conflictos |
| `DEPLOY_HOST` | secret | Host o IP de la VM Oracle |
| `DEPLOY_USER` | secret | Usuario de deploy (`ubuntu`) |
| `DEPLOY_SSH_KEY` | secret | Clave privada ed25519 del usuario de deploy |
| `DEPLOY_KNOWN_HOSTS` | secret | Línea de host key fijada (`ssh-keyscan -t ed25519 <host>`). Si está vacío el deploy falla: nunca se desactiva la verificación de host |
| `DEPLOY_HEALTHCHECK_URL` | variable | Opcional. Por defecto `https://app.pymeinteligente.online/healthz` (pasa por Contabo y el túnel) |

Los secrets `VPS_*` del esquema anterior ya no se usan y se pueden borrar.

### Qué hace `deploy.sh`

Corre en la VM como el usuario de deploy y deja el log en `/opt/twenty/deploy.log`.
Los nombres propios de este server están en un bloque de variables al principio.

1. Verifica docker, el compose, `.env`, al menos 8 GB libres y que
   `twenty_db_oracle` esté corriendo.
2. `docker pull` de la imagen nueva, todavía sin cortar el servicio.
3. **Detiene `server` y `worker`.** Desde acá hasta el paso 7 el CRM está caído:
   el código viejo no puede escribir mientras se toma el dump ni mientras se
   migra el schema, porque lo escrito después del dump se perdería al restaurar.
4. **Dump previo** `pg_dump -Fc` a `/opt/twenty/backups/predeploy-<fecha>.dump`,
   verificado con `pg_restore --list`. Si falla, vuelve a levantar la versión
   actual y aborta sin haber cambiado nada.
5. Deja la imagen en uso como `twenty-fork:arm64-previous` y etiqueta la nueva
   como `twenty-fork:arm64`.
6. Corre el upgrade con la imagen **nueva** (`cache:flush`, `upgrade`,
   `cache:flush`). Si falla, restaura el tag anterior y levanta la versión
   vieja. **No restaura la base**: puede haber quedado parcialmente migrada.
7. `docker compose up -d server worker` y espera hasta 5 minutos a que
   `twenty_server_oracle` esté `healthy`, y además a que
   `http://127.0.0.1:3000/healthz` responda desde el host (es el puerto que
   reenvía el túnel). Si no, vuelve a la imagen anterior.
8. Limpia imágenes viejas y dumps `predeploy-*` de más de 14 días.

**Las migraciones no corren solas.** El compose fija `DISABLE_DB_MIGRATIONS=true`
en server y worker: un reinicio común nunca migra; solo lo hace `deploy.sh`.

### Ejecutar a mano

En GitHub: Actions > "Fork upstream sync" > Run workflow. Parámetros:

- `upstream_tag`: tag a mergear (por ejemplo `twenty/v2.46.0`). Vacío = el último.
- `deploy_only`: no mergea; reconstruye y despliega el `main` actual.

O con la CLI: `gh workflow run fork-upstream-sync.yaml -f deploy_only=true`.

Directo en la VM, con una imagen ya publicada (hace falta `docker login ghcr.io`
previo, porque el paquete es privado):

```bash
ssh ubuntu@<host> 'bash -s -- ghcr.io/bautibadino/twenty-fork:<sha>' < deploy/oracle/deploy.sh
```

### Volver atrás a mano

Solo la imagen (el schema no cambió, o la versión anterior lo tolera):

```bash
cd /opt/twenty
docker tag twenty-fork:arm64-previous twenty-fork:arm64
docker compose -f docker-compose.oracle.yml up -d --force-recreate server worker
```

Si el deploy corrió migraciones de schema, volver a la imagen anterior **no**
alcanza: hay que restaurar también el dump pre-deploy.

### Restaurar el dump pre-deploy

Es la única vía de vuelta después de un upgrade de schema. Se pierden los datos
escritos desde que se tomó el dump.

```bash
cd /opt/twenty
ls -lt backups/predeploy-*.dump | head -3          # elegir el dump
docker compose -f docker-compose.oracle.yml stop server worker
docker exec -i twenty_db_oracle pg_restore -U twenty -d default --clean --if-exists \
  < backups/predeploy-<STAMP>.dump
docker tag twenty-fork:arm64-previous twenty-fork:arm64
docker compose -f docker-compose.oracle.yml up -d server worker
```

(`twenty` y `default` son los valores de `PG_DATABASE_USER` y `PG_DATABASE_NAME`
del `.env`.)

## Backup diario

`backup-twenty.sh` hace un `pg_dump -Fc` verificado de la base y un `tar.gz` del
volumen de storage, a `/opt/twenty/backups`, con retención de 30 días. Corta con
exit distinto de cero y una línea `ERROR` si algo falla; en particular, si
`twenty_db_oracle` no está corriendo **no** escribe un archivo vacío. El tar usa
la imagen `postgres:16` (la misma del servicio `db`: ya está en la VM, es
multi-arch y trae `tar`).

Instalación en la VM (una sola vez):

```bash
cd /opt/twenty
# copiar backup-twenty.sh a /opt/twenty (scp desde el repo) y:
chmod +x /opt/twenty/backup-twenty.sh
mkdir -p /opt/twenty/backups
(crontab -l 2>/dev/null | grep -v backup-twenty; \
 echo "15 3 * * * /opt/twenty/backup-twenty.sh >> /opt/twenty/backups/backup.log 2>&1") | crontab -
```

Revisar de vez en cuando `tail /opt/twenty/backups/backup.log`: el cron avisa
fallando, pero nadie lo lee si no se mira. Los backups viven en el mismo disco que
la base; copiarlos fuera de la VM es una mejora pendiente.

### Restaurar un backup diario

```bash
cd /opt/twenty
docker compose -f docker-compose.oracle.yml stop server worker

# Base completa (borra y recrea el contenido actual)
docker exec -i twenty_db_oracle pg_restore -U twenty -d default --clean --if-exists \
  < backups/twenty-db-<STAMP>.dump

# Solo el schema de un workspace
docker exec -i twenty_db_oracle pg_restore -U twenty -d default --schema=workspace_<id> \
  < backups/twenty-db-<STAMP>.dump

# Archivos
docker run --rm --entrypoint tar -v twenty-oracle_twenty-storage-oracle:/data \
  -v /opt/twenty/backups:/in postgres:16 xzf /in/twenty-storage-<STAMP>.tar.gz -C /data
# el contenedor del CRM corre como uid 1000
docker run --rm -u 0 -v twenty-oracle_twenty-storage-oracle:/data postgres:16 \
  chown -R 1000:1000 /data

docker compose -f docker-compose.oracle.yml up -d server worker
```

## Alta de un workspace nuevo (subdominio)

Cada workspace vive en `<slug>.pymeinteligente.online`. Traefik en Contabo tiene
**un router `Host()` por subdominio conocido**, cada uno con
`tls.certResolver: letsencrypt`. Hoy: `app`, `sharp-beige-leopard`, `bym-srl` y
`sport`. Un subdominio que no figura cae en un router `HostRegexp` de respaldo que
**no tiene certificado válido**: el workspace funciona, pero el navegador muestra
error de certificado.

Para dar de alta uno nuevo, en Contabo:

1. Verificar que el DNS de `<slug>.pymeinteligente.online` apunte a Contabo
   (147.93.183.23); sin eso falla el challenge HTTP-01.
2. Editar `/opt/woocommerce-platform/traefik/dynamic/twenty-oracle.yml` y agregar
   un router igual a los existentes, cambiando solo el host:

   ```yaml
   http:
     routers:
       twenty-<slug>:
         rule: "Host(`<slug>.pymeinteligente.online`)"
         service: <el mismo service que usan los otros routers>
         entryPoints: [websecure]
         tls:
           certResolver: letsencrypt
   ```

   Copiar la estructura exacta de un router existente: el bloque de arriba es
   ilustrativo.
3. Traefik recarga el archivo dinámico solo. Esperar unos segundos y comprobar
   `curl -sI https://<slug>.pymeinteligente.online/healthz` y el certificado
   (`openssl s_client -connect <slug>.pymeinteligente.online:443 -servername <slug>.pymeinteligente.online </dev/null | openssl x509 -noout -issuer -dates`).

## Certificados: por qué ya no hay wildcard

El certificado wildcard `*.pymeinteligente.online` lo emitía `acme.sh` con
desafío DNS **manual** en DonWeb, que no tiene API: cada renovación exigía crear a
mano un registro TXT. Venció el 2026-09-28 y se retiró. En su lugar, cada
subdominio tiene su propio certificado Let's Encrypt por HTTP-01, emitido y
renovado automáticamente por el `certResolver: letsencrypt` de Traefik. El costo
es el paso de arriba: un subdominio nuevo requiere su router explícito.

## Rollback a Contabo

El stack de Contabo (`/opt/twenty` allá, contenedores `twenty_db`, `twenty_server`,
etc.; ver `deploy/vps/`) está **detenido, no borrado**, y se conserva solo para
volver atrás. Antes de usarlo, tener en cuenta:

- Su base quedó congelada el 2026-08-30. Todo lo cargado en Oracle desde
  entonces no está ahí. Para no perderlo hay que tomar un dump de
  `twenty_db_oracle` y restaurarlo en `twenty_db` de Contabo (y copiar el
  storage), con el mismo `APP_SECRET`.
- Traefik tiene que volver a apuntar al contenedor de Contabo (labels del
  compose viejo, `HostRegexp`) y los routers hacia el túnel de
  `twenty-oracle.yml` deben desactivarse.
- La imagen de Contabo es amd64 (`twenty-fork:latest` allá) y su versión es
  anterior; si la base restaurada tiene un schema más nuevo que esa imagen, no
  arranca.
- Su cron de backup genera dumps vacíos desde la mudanza.

## Variables de entorno

La plantilla es `.env.example`. Las que no tienen valor por defecto razonable:
`PG_DATABASE_PASSWORD`, `APP_SECRET` (cambiarlo desloguea a todos y deja
inutilizables los datos cifrados), `EMAIL_SMTP_PASSWORD`. Con `EMAIL_DRIVER=smtp`
el compose pasa `EMAIL_SMTP_HOST/PORT/USER/PASSWORD` a server y worker; si falta
alguna, no sale ningún mail.
