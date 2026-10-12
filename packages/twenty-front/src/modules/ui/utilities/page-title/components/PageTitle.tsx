import { appNameState } from '@/client-config/states/appNameState';
import { useAtomStateValue } from '@/ui/utilities/state/jotai/hooks/useAtomStateValue';
import { Helmet } from '@dr.pogodin/react-helmet';

import { useWorkspaceSurface } from '@/ui/layout/hooks/useWorkspaceSurface';

type PageTitleProps = {
  title: string;
};

// Single place where the tab <title> is built, so the product name suffix
// applies to every page without touching them one by one.
export const PageTitle = (props: PageTitleProps) => {
  const appName = useAtomStateValue(appNameState);
  const workspaceSurface = useWorkspaceSurface();

  if (workspaceSurface.type === 'side-panel') {
    return null;
  }

  // Avoids "PymeInteligente CRM · PymeInteligente CRM" on pages whose title is
  // already the product name.
  const title = props.title.includes(appName)
    ? props.title
    : `${props.title} · ${appName}`;

  return (
    <Helmet>
      <title>{title}</title>
    </Helmet>
  );
};
