// Sincroniza contactos de Whaticket taggeados con medidas de neumatico de camion
// (rines "y medio": R17.5, R19.5, R22.5, R24.5, etc.) hacia Twenty, como
// Person + Opportunity de seguimiento.
//
// No crea Company automaticamente: Whaticket casi nunca tiene el nombre de
// la empresa/flota cargado (solo el nombre de la persona), asi que crear una
// Company por contacto termina llenando el CRM de tarjetas sueltas sin
// agrupar nada real. El agrupamiento por flota se hace a mano en Twenty
// cuando se identifica (arrastrando el Person a una Company existente).
//
// No hay webhook de Whaticket para esto -> este script corre por cron
// (cada 1-2 horas alcanza de sobra para seguimiento de flotas B2B).

const {
  WHATICKET_API_URL = 'https://api.whaticket.com/api/v1',
  WHATICKET_API_TOKEN,
  TWENTY_API_URL,
  TWENTY_API_KEY,
  TRUCK_TAG_REGEX = 'R\\d{2}\\.5',
  TWENTY_TRUCK_TAGS_FIELD_NAME = 'truckTireSizes',
  DEFAULT_PHONE_CALLING_CODE = '+54',
  DEFAULT_PHONE_COUNTRY_CODE = 'AR',
} = process.env;

function requireEnv() {
  const missing = ['WHATICKET_API_TOKEN', 'TWENTY_API_URL', 'TWENTY_API_KEY'].filter(
    (key) => !process.env[key],
  );
  if (missing.length > 0) {
    throw new Error(`Faltan variables de entorno: ${missing.join(', ')}`);
  }
}

const truckTagPattern = new RegExp(TRUCK_TAG_REGEX, 'i');

// ---------- Whaticket ----------

async function fetchAllWhaticketContacts() {
  const contacts = [];
  let pageNumber = 1;
  let hasMore = true;

  while (hasMore) {
    const res = await fetch(
      `${WHATICKET_API_URL}/contacts?pageNumber=${pageNumber}`,
      { headers: { Authorization: `Bearer ${WHATICKET_API_TOKEN}` } },
    );
    if (!res.ok) {
      throw new Error(
        `Whaticket API error ${res.status} en /contacts (pagina ${pageNumber}): ${await res.text()}`,
      );
    }
    const data = await res.json();
    contacts.push(...(data.contacts ?? []));
    hasMore = Boolean(data.hasMore);
    pageNumber += 1;
  }

  return contacts;
}

function matchedTruckTags(contact) {
  return (contact.tags ?? [])
    .map((tag) => tag.name)
    .filter((name) => truckTagPattern.test(name));
}

// ---------- Twenty ----------
// La API de Twenty rate-limitea a 100 requests / 60s. Espaciamos las
// llamadas para quedar comodos por debajo (1 cada 700ms ~ 85/min) y
// reintentamos con backoff si igual llega un 429.

const TWENTY_MIN_INTERVAL_MS = 700;
let lastTwentyRequestAt = 0;

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function throttleTwentyRequest() {
  const elapsed = Date.now() - lastTwentyRequestAt;
  if (elapsed < TWENTY_MIN_INTERVAL_MS) {
    await sleep(TWENTY_MIN_INTERVAL_MS - elapsed);
  }
  lastTwentyRequestAt = Date.now();
}

async function twentyRequest(path, options = {}, attempt = 1) {
  await throttleTwentyRequest();

  const res = await fetch(`${TWENTY_API_URL}${path}`, {
    ...options,
    headers: {
      Authorization: `Bearer ${TWENTY_API_KEY}`,
      'Content-Type': 'application/json',
      ...options.headers,
    },
  });

  if (res.status === 429 && attempt <= 5) {
    const retryAfterHeader = Number(res.headers.get('retry-after'));
    const waitMs = Number.isFinite(retryAfterHeader) && retryAfterHeader > 0
      ? retryAfterHeader * 1000
      : attempt * 2000;
    await sleep(waitMs);
    return twentyRequest(path, options, attempt + 1);
  }

  if (!res.ok) {
    throw new Error(
      `Twenty API error ${res.status} en ${path}: ${await res.text()}`,
    );
  }
  return res.status === 204 ? null : res.json();
}

async function fetchAllTwenty(objectNamePlural) {
  const records = [];
  let cursor;

  for (;;) {
    const params = new URLSearchParams({ limit: '100' });
    if (cursor) params.set('starting_after', cursor);

    const page = await twentyRequest(`/${objectNamePlural}?${params}`);
    const pageRecords = page?.data?.[objectNamePlural] ?? [];
    records.push(...pageRecords);

    if (!page?.pageInfo?.hasNextPage) break;
    cursor = page.pageInfo.endCursor;
  }

  return records;
}

function normalizePhone(rawNumber) {
  return String(rawNumber ?? '').replace(/\D/g, '');
}

function splitName(fullName) {
  const parts = String(fullName ?? '').trim().split(/\s+/).filter(Boolean);
  const firstName = parts.shift() || 'Contacto Whaticket';
  const lastName = parts.join(' ') || '-';
  return { firstName, lastName };
}

async function findOrUpdatePerson({
  contact,
  truckTags,
  peopleByPhone,
  created,
  updated,
}) {
  const phone = normalizePhone(contact.number);
  const existing = peopleByPhone.get(phone);
  const tagsValue = truckTags.join(', ');

  if (existing) {
    const needsTagsUpdate = existing[TWENTY_TRUCK_TAGS_FIELD_NAME] !== tagsValue;

    if (needsTagsUpdate) {
      const result = await twentyRequest(`/people/${existing.id}`, {
        method: 'PATCH',
        body: JSON.stringify({ [TWENTY_TRUCK_TAGS_FIELD_NAME]: tagsValue }),
      });
      updated.people += 1;
      return result.data.updatePerson;
    }
    return existing;
  }

  const { firstName, lastName } = splitName(contact.name);
  const result = await twentyRequest('/people', {
    method: 'POST',
    body: JSON.stringify({
      name: { firstName, lastName },
      phones: {
        primaryPhoneNumber: contact.number,
        primaryPhoneCallingCode: DEFAULT_PHONE_CALLING_CODE,
        primaryPhoneCountryCode: DEFAULT_PHONE_COUNTRY_CODE,
      },
      ...(contact.email ? { emails: { primaryEmail: contact.email } } : {}),
      [TWENTY_TRUCK_TAGS_FIELD_NAME]: tagsValue,
    }),
  });
  const person = result.data.createPerson;
  peopleByPhone.set(phone, person);
  created.people += 1;
  return person;
}

async function ensureOpportunity({
  person,
  truckTags,
  opportunitiesByPersonId,
  created,
}) {
  if (opportunitiesByPersonId.has(person.id)) return;

  const result = await twentyRequest('/opportunities', {
    method: 'POST',
    body: JSON.stringify({
      name: `Seguimiento flota - ${truckTags.join(', ')}`,
      pointOfContactId: person.id,
    }),
  });
  opportunitiesByPersonId.set(person.id, result.data.createOpportunity);
  created.opportunities += 1;
}

// ---------- Main ----------

async function main() {
  requireEnv();

  console.log('Buscando contactos de Whaticket...');
  const contacts = await fetchAllWhaticketContacts();
  const fleetContacts = contacts
    .map((contact) => ({ contact, truckTags: matchedTruckTags(contact) }))
    .filter(({ truckTags }) => truckTags.length > 0);

  console.log(
    `${contacts.length} contactos totales, ${fleetContacts.length} con etiqueta de camion.`,
  );

  console.log('Cargando People y Opportunities existentes de Twenty...');
  const [existingPeople, existingOpportunities] = await Promise.all([
    fetchAllTwenty('people'),
    fetchAllTwenty('opportunities'),
  ]);

  const peopleByPhone = new Map(
    existingPeople
      .filter((person) => person.phones?.primaryPhoneNumber)
      .map((person) => [normalizePhone(person.phones.primaryPhoneNumber), person]),
  );
  const opportunitiesByPersonId = new Map(
    existingOpportunities
      .filter((opportunity) => opportunity.pointOfContactId)
      .map((opportunity) => [opportunity.pointOfContactId, opportunity]),
  );

  const created = { people: 0, opportunities: 0 };
  const updated = { people: 0 };

  for (const { contact, truckTags } of fleetContacts) {
    try {
      const person = await findOrUpdatePerson({
        contact,
        truckTags,
        peopleByPhone,
        created,
        updated,
      });
      await ensureOpportunity({
        person,
        truckTags,
        opportunitiesByPersonId,
        created,
      });
    } catch (error) {
      console.error(
        `Error procesando contacto ${contact.name} (${contact.number}):`,
        error.message,
      );
    }
  }

  console.log('Listo.', { created, updated });
}

main().catch((error) => {
  console.error('Sync fallo:', error);
  process.exitCode = 1;
});
