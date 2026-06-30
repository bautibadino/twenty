# Twenty CRM — Configuración SaaS multi-tenant (Railway)

Esta guía documenta las variables de entorno necesarias para operar este fork de Twenty
como un SaaS multi-tenant self-service. Todas se configuran en Railway (no se hardcodean).

## 1. Multi-workspace y signup self-service

| Variable | Valor recomendado | Por qué |
|----------|-------------------|---------|
| `IS_MULTIWORKSPACE_ENABLED` | `true` | Habilita múltiples workspaces (uno por empresa). Cada uno con su propio schema de Postgres (`workspace_<id>`), aislamiento total a nivel DB. |
| `IS_WORKSPACE_CREATION_LIMITED_TO_SERVER_ADMINS` | `false` | **CRÍTICO.** Si es `true`, solo los server-admins pueden crear workspaces y el self-service público NO funciona (un cliente nuevo recibe "Workspace creation is restricted to admins"). Para SaaS público debe ser `false`. |
| `MAX_WORKSPACES_LIMIT` | `100000` | Límite de workspaces sin enterprise key. Default `5`. Subir alto para SaaS sin límite artificial. (Fase 1) |
| `AUTH_PASSWORD_ENABLED` | `true` | Permite registro con email + contraseña. |
| `IS_EMAIL_VERIFICATION_REQUIRED` | `true` | Activa el envío del mail de verificación durante el signup. Si es `false`, el mail NO se envía y se saltea ese paso. |

### Flujo resultante para un cliente nuevo
1. Va a la URL pública → ingresa email.
2. Define contraseña.
3. Recibe y confirma el mail de verificación.
4. Queda logueado → pantalla "nombrá tu workspace" (nombre de empresa + subdominio opcional).
5. Entra a su workspace aislado, listo para usar.

## 2. Email (SMTP)

Necesario para verificación de cuenta, invitaciones y notificaciones de billing.

| Variable | Ejemplo |
|----------|---------|
| `EMAIL_DRIVER` | `SMTP` |
| `EMAIL_SMTP_HOST` | `smtp.tu-proveedor.com` |
| `EMAIL_SMTP_PORT` | `587` |
| `EMAIL_SMTP_USER` | `apikey` / usuario SMTP |
| `EMAIL_SMTP_PASSWORD` | (secreto) |
| `EMAIL_FROM_ADDRESS` | `noreply@tudominio.com` |
| `EMAIL_FROM_NAME` | `Tu Producto` |

## 3. Billing (Stripe)

| Variable | Valor | Por qué |
|----------|-------|---------|
| `IS_BILLING_ENABLED` | `true` | Master switch de todo el billing. |
| `BILLING_STRIPE_API_KEY` | `sk_live_...` | API key secreta de Stripe. |
| `BILLING_STRIPE_WEBHOOK_SECRET` | `whsec_...` | Verifica la firma del webhook `POST /webhooks/stripe`. |
| `BILLING_STRIPE_PUBLISHABLE_KEY` | `pk_live_...` | Inicializa Stripe Elements en el frontend (formulario de tarjeta). |
| `BILLING_FREE_TRIAL_WITH_CREDIT_CARD_DURATION_IN_DAYS` | `30` | Trial con tarjeta. |
| `BILLING_FREE_TRIAL_WITHOUT_CREDIT_CARD_DURATION_IN_DAYS` | `7` | Trial sin tarjeta. |

### Configuración en Stripe
- Los planes/precios se leen **desde Stripe vía API**, no se hardcodean. Hay que crear en Stripe
  los Products con metadata `productKey` = `BASE_PRODUCT` (precio por asiento) y `RESOURCE_CREDIT`.
- Webhook de Stripe: apuntar a `https://<tu-dominio>/webhooks/stripe` y suscribir los eventos
  de subscription (created/updated/deleted), invoice (paid/finalized), setup_intent y payment_method.
- Copiar el signing secret del webhook a `BILLING_STRIPE_WEBHOOK_SECRET`.

### Comportamiento ya implementado (no requiere código)
- Checkout con tarjeta vía Stripe Elements → suscripción activa.
- Suspensión automática del workspace (`activationStatus = SUSPENDED`) ante impago/cancelación.
- Reactivación automática cuando el pago se regulariza.
- Portal de cliente de Stripe accesible desde Settings → Billing (cambiar tarjeta, ver facturas, cancelar).

## 4. Branding (Fase 4)

| Variable | Default | Aplica en |
|----------|---------|-----------|
| `APP_NAME` | `Twenty` | Login (título "Welcome to ..."), footer legal, y nombre de producto en la UI. El sidebar ya muestra el nombre/logo del propio workspace (brandeable por cada tenant). |
| `APP_LOGO_URL` | (logo Twenty) | Logo en la página de login y la landing. URL absoluta a una imagen. |

### Emails
El branding del **remitente** de los emails se controla con `EMAIL_FROM_NAME` / `EMAIL_FROM_ADDRESS` (sección 2) — es lo que ve el destinatario como "From: Mi CRM <noreply@...>".

El cuerpo de los emails (plantillas React Email) tiene textos y footer específicos de Twenty traducidos vía i18n. Re-brandearlos por completo es un trabajo aparte (tocar el catálogo i18n y quitar el footer/promo de Twenty) y queda como follow-up; no afecta la operación del SaaS.

## 5. Landing page pública (Fase 5)

| Variable | Default | Efecto |
|----------|---------|--------|
| `IS_LANDING_PAGE_ENABLED` | `false` | Cuando es `true`, la raíz `/` sirve una landing pública (con el `APP_NAME`, `APP_LOGO_URL` y un CTA "Empezá gratis" → `/welcome`) en vez de redirigir al visitante anónimo al login. Cuando es `false`, se mantiene el comportamiento actual (anónimo en `/` → `/welcome`). Usuarios logueados siempre van a su dashboard. |

## 6. Selector de planes (Fase 3)

El checkout muestra automáticamente un selector de **plan** (PRO / ENTERPRISE) y de **intervalo** (mensual / anual) cuando hay más de un plan o más de un intervalo configurado en Stripe. Con un solo plan/intervalo, el selector no aparece (no hay nada que elegir). Los planes y precios se definen en Stripe (Products con metadata `planKey` = `PRO` / `ENTERPRISE` y `productKey` = `BASE_PRODUCT`).
