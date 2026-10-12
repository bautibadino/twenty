import { Font, Head } from 'react-email';

import { canvasTheme } from 'src/common-style';
import { getAppName } from 'src/utils/branding';

export const BaseHead = () => {
  return (
    <Head>
      <title>{`${getAppName()} email`}</title>
      <Font
        fontFamily={canvasTheme.font.family}
        fallbackFontFamily="sans-serif"
        fontStyle="normal"
        fontWeight={canvasTheme.font.weight.regular}
      />
    </Head>
  );
};
