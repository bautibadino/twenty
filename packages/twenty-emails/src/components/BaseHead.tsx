import { Font, Head } from '@react-email/components';

import { emailTheme } from 'src/common-style';
import { getAppName } from 'src/utils/branding';

export const BaseHead = () => {
  return (
    <Head>
      <title>{`${getAppName()} email`}</title>
      <Font
        fontFamily={emailTheme.font.family}
        fallbackFontFamily="sans-serif"
        fontStyle="normal"
        fontWeight={emailTheme.font.weight.regular}
      />
    </Head>
  );
};
