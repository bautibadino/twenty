const DEFAULT_APP_NAME = 'Twenty';

const DEFAULT_LOGO_URL =
  'https://app.twenty.com/images/icons/windows11/Square150x150Logo.scale-100.png';

export const getAppName = () => process.env.APP_NAME?.trim() || DEFAULT_APP_NAME;

/**
 * Con APP_NAME sin definir todo queda exactamente igual que en upstream:
 * mismos textos, mismo logo, mismo footer.
 */
export const isCustomBranded = () => getAppName() !== DEFAULT_APP_NAME;

/**
 * Los catálogos i18n tienen la marca incrustada dentro de la frase ya
 * traducida ("Únete a tu equipo en Twenty"). Traducimos primero y sustituimos
 * la marca después: así no perdemos el idioma ni hay que mantener catálogos
 * propios para cada locale.
 */
export const withAppName = (translated: string) =>
  isCustomBranded()
    ? translated.split(DEFAULT_APP_NAME).join(getAppName())
    : translated;

/**
 * Logo para los emails. Es un caso aparte del logo de la UI: Gmail no renderiza
 * SVG en emails, así que un .svg se vería como imagen rota. Preferimos
 * APP_EMAIL_LOGO_URL (raster), caemos a APP_LOGO_URL solo si no es SVG, y si no
 * hay ninguno servible devolvemos null para no mostrar una imagen rota.
 */
export const getEmailLogoUrl = (): string | null => {
  const emailLogo = process.env.APP_EMAIL_LOGO_URL?.trim();

  if (emailLogo) {
    return emailLogo;
  }

  if (!isCustomBranded()) {
    return DEFAULT_LOGO_URL;
  }

  const appLogo = process.env.APP_LOGO_URL?.trim();

  if (appLogo && !appLogo.toLowerCase().endsWith('.svg')) {
    return appLogo;
  }

  return null;
};
