import { createAtomState } from '@/ui/utilities/state/jotai/utils/createAtomState';

export const appLogoUrlState = createAtomState<string | undefined>({
  key: 'appLogoUrl',
  defaultValue: undefined,
});
