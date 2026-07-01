# whaticket-fleet-sync

Sincroniza hacia Twenty los contactos de Whaticket que tengan una etiqueta de
medida de neumatico de camion (rines "y medio": `R17.5`, `R19.5`, `R22.5`,
`R24.5`), como seguimiento de flotas.

Por que existe: Whaticket no tiene webhook saliente (confirmado con su propia
documentacion — la API solo permite *enviar* contactos/mensajes, no notifica
mensajes o tickets entrantes). Para este caso de uso (seguimiento B2B de
flotas) no hace falta tiempo real: este script corre por cron cada 1-2 horas
y usa `GET /contacts`, que si devuelve las etiquetas de cada contacto.

Es un proyecto standalone, no forma parte del workspace de Yarn/Nx de este
repo (no esta listado en `package.json` -> `workspaces`), para no mezclar
logica especifica de un cliente con el codigo compartido de Twenty.

## Que hace en Twenty

Por cada contacto de Whaticket con etiqueta de camion:

- Busca (por telefono) o crea una **Person**, con las medidas detectadas
  guardadas en un campo custom de texto.
- Crea una **Opportunity** de seguimiento vinculada a esa Person (una sola
  vez, no duplica en corridas siguientes).

No crea Company automaticamente: en la primera corrida real (498 contactos)
se probo crear una Company por contacto (usando el nombre de Whaticket como
proxy de "flota") y el resultado fue ~487 Companies, casi todas nombres de
personas sueltas, no flotas reales — mas ruido que valor. El agrupamiento
por flota se hace a mano en Twenty: cuando identifiques que varios Person
pertenecen a la misma flota, creás la Company una vez y les asignás el
`companyId` desde la UI.

## Setup (una sola vez)

1. **Token de Whaticket**: en `app.whaticket.com` -> Tokens -> crear uno con
   permiso `read:contacts`.
2. **API Key de Twenty**: en tu Twenty -> Settings -> Developers -> API Keys
   -> crear una con permisos sobre People y Opportunities.
3. **Campo custom en Twenty**: Settings -> Data Model -> Person -> agregar
   campo tipo *Text*, label "Truck Tire Sizes" (para que el nombre de API
   generado sea simple). Anota el nombre de API que Twenty le asigna y
   ponelo en `TWENTY_TRUCK_TAGS_FIELD_NAME` en tu `.env` si es distinto de
   `truckTireSizes`.
4. Copiar `.env.example` a `.env` y completar los valores (token, API key,
   URL de tu Twenty).

## Uso

Sin dependencias externas (usa `fetch` nativo de Node >= 20.6). No hace falta
`yarn install`/`npm install`.

```bash
node --env-file=.env src/sync.mjs
```

## Deploy como cron (en tu propio servidor)

Ejemplo de crontab corriendo cada hora:

```
0 * * * * cd /ruta/a/whaticket-fleet-sync && /usr/bin/node --env-file=.env src/sync.mjs >> sync.log 2>&1
```

## Limitaciones conocidas

- No sincroniza el contenido de los mensajes/conversacion, solo el contacto
  y sus etiquetas (Whaticket no expone un endpoint de lectura de tickets o
  mensajes en su API publica).
- No agrupa por flota/Company automaticamente (ver arriba). Eso queda como
  paso manual en Twenty hasta que definamos una fuente confiable del nombre
  de la empresa (hoy Whaticket no la tiene cargada para casi ningun contacto).
- El telefono se guarda con codigo de pais fijo (`DEFAULT_PHONE_CALLING_CODE`
  / `DEFAULT_PHONE_COUNTRY_CODE` en `.env`), pensado para Argentina.
- La API de Twenty rate-limitea a 100 requests/60s; el script ya espacia sus
  llamadas y reintenta con backoff en 429, pero corridas grandes (cientos de
  contactos) tardan varios minutos por diseño.
