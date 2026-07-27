import { appNameState } from '@/client-config/states/appNameState';
import { useAtomStateValue } from '@/ui/utilities/state/jotai/hooks/useAtomStateValue';
import { Helmet } from '@dr.pogodin/react-helmet';

type PageTitleProps = {
  title: string;
};

/**
 * Punto único donde se arma el <title> de la pestaña, así que el sufijo con el
 * nombre del producto se aplica a todas las páginas sin tocarlas una por una.
 */
export const PageTitle = (props: PageTitleProps) => {
  const appName = useAtomStateValue(appNameState);

  // Evita "PymeInteligente CRM · PymeInteligente CRM" en las páginas cuyo
  // título ya es el nombre del producto.
  const title = props.title.includes(appName)
    ? props.title
    : `${props.title} · ${appName}`;

  return (
    <Helmet>
      <title>{title}</title>
    </Helmet>
  );
};
