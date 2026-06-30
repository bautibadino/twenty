import { createAtomState } from '@/ui/utilities/state/jotai/utils/createAtomState';

export const isLandingPageEnabledState = createAtomState<boolean>({
  key: 'isLandingPageEnabled',
  defaultValue: false,
});
