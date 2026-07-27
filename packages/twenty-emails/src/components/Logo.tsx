import { Img } from '@react-email/components';
import { getAppName, getEmailLogoUrl } from 'src/utils/branding';

const logoStyle = {
  marginBottom: '40px',
};

export const Logo = () => {
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
      alt={`${getAppName()} logo`}
      height="40"
      style={logoStyle}
    />
  );
};
