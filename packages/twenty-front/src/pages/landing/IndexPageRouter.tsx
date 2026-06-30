import { useHasAccessTokenPair } from '@/auth/hooks/useHasAccessTokenPair';
import { isLandingPageEnabledState } from '@/client-config/states/isLandingPageEnabledState';
import { LandingPage } from '~/pages/landing/LandingPage';
import { useAtomStateValue } from '@/ui/utilities/state/jotai/hooks/useAtomStateValue';

// Decides what renders at the root path (/).
// - Anonymous visitor + landing enabled -> public marketing landing.
// - Otherwise renders nothing; usePageChangeEffectNavigateLocation redirects
//   authenticated users to their home page and anonymous users to /welcome.
export const IndexPageRouter = () => {
  const hasAccessTokenPair = useHasAccessTokenPair();
  const isLandingPageEnabled = useAtomStateValue(isLandingPageEnabledState);

  if (!hasAccessTokenPair && isLandingPageEnabled) {
    return <LandingPage />;
  }

  return <></>;
};
