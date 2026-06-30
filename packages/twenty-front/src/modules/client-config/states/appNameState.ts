import { createAtomState } from '@/ui/utilities/state/jotai/utils/createAtomState';

export const appNameState = createAtomState<string>({
  key: 'appName',
  defaultValue: 'Twenty',
});
