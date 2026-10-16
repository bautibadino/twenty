import { type I18n } from '@lingui/core';
import { Img } from 'react-email';
import { getEmailLogoUrl, withAppName } from 'src/utils/branding';

const logoStyle = {
  marginBottom: '40px',
};

type LogoProps = {
  i18n: I18n;
};

export const Logo = ({ i18n }: LogoProps) => {
  const logoUrl = getEmailLogoUrl();

  // Sin logo servible preferimos no renderizar nada antes que una imagen rota.
  if (!logoUrl) {
    return <></>;
  }

  // Alto fijo y ancho automático: el logo del deploy puede ser un wordmark
  // apaisado, no necesariamente un cuadrado como el de Twenty.
  return (
    <Img
      src={logoUrl}
      alt={withAppName(i18n._('Twenty logo'))}
      height="40"
      style={logoStyle}
    />
  );
};
