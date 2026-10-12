import { useIsLogged } from '@/auth/hooks/useIsLogged';
import { RecordIndexSkeletonLoader } from '@/object-record/record-index/components/RecordIndexSkeletonLoader';
import { isLandingPageEnabledState } from '@/client-config/states/isLandingPageEnabledState';
import { LandingPage } from '~/pages/landing/LandingPage';
import { useAtomStateValue } from '@/ui/utilities/state/jotai/hooks/useAtomStateValue';

// Decides what renders at the root path (/).
// - Anonymous visitor + landing enabled -> public marketing landing.
// - Otherwise renders the upstream index skeleton while
//   usePageChangeEffectNavigateLocation redirects
//   authenticated users to their home page and anonymous users to /welcome.
export const IndexPageRouter = () => {
  const isLogged = useIsLogged();
  const isLandingPageEnabled = useAtomStateValue(isLandingPageEnabledState);

  if (!isLogged && isLandingPageEnabled) {
    return <LandingPage />;
  }

  return <RecordIndexSkeletonLoader />;
};
