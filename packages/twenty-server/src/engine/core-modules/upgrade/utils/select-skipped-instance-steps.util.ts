import { type UpgradeStepKind } from 'src/engine/core-modules/upgrade/services/upgrade-sequence-reader.service';

type SelectableUpgradeStep = {
  kind: UpgradeStepKind;
  name: string;
};

const isInstanceStep = (step: SelectableUpgradeStep): boolean =>
  step.kind === 'fast-instance' || step.kind === 'slow-instance';

// Instance steps positioned before the upgrade cursor that were never
// completed. `upgrade` skips them when a command was registered in an
// already-released version after the database had moved past it.
// Steps before the first completed instance step are treated as history that
// predates the upgrade registry and are never selected.
export const selectSkippedInstanceSteps = <
  TStep extends SelectableUpgradeStep,
>({
  sequence,
  cursor,
  completedInstanceStepNames,
}: {
  sequence: TStep[];
  cursor: number;
  completedInstanceStepNames: ReadonlySet<string>;
}): TStep[] => {
  const stepsBeforeCursor = sequence.slice(0, cursor);

  const firstCompletedIndex = stepsBeforeCursor.findIndex(
    (step) => isInstanceStep(step) && completedInstanceStepNames.has(step.name),
  );

  if (firstCompletedIndex === -1) {
    return [];
  }

  return stepsBeforeCursor
    .slice(firstCompletedIndex)
    .filter(
      (step) =>
        isInstanceStep(step) && !completedInstanceStepNames.has(step.name),
    );
};
