import { type UpgradeStepKind } from 'src/engine/core-modules/upgrade/services/upgrade-sequence-reader.service';
import { selectSkippedInstanceSteps } from 'src/engine/core-modules/upgrade/utils/select-skipped-instance-steps.util';

type TestStep = { kind: UpgradeStepKind; name: string };

const step = (kind: UpgradeStepKind, name: string): TestStep => ({
  kind,
  name,
});

const namesOf = (steps: TestStep[]) => steps.map(({ name }) => name);

describe('selectSkippedInstanceSteps', () => {
  it('should select nothing when every instance step before the cursor is completed', () => {
    const sequence = [
      step('fast-instance', 'a-fast'),
      step('slow-instance', 'a-slow'),
      step('workspace', 'a-ws'),
      step('fast-instance', 'b-fast'),
    ];

    expect(
      selectSkippedInstanceSteps({
        sequence,
        cursor: 3,
        completedInstanceStepNames: new Set(['a-fast', 'a-slow']),
      }),
    ).toEqual([]);
  });

  it('should select the instance steps registered late in the version of the last attempted workspace command', () => {
    const sequence = [
      step('fast-instance', '2.17-fast'),
      step('workspace', '2.17-ws'),
      step('fast-instance', '2.18-fast-1'),
      step('fast-instance', '2.18-fast-late'),
      step('slow-instance', '2.18-slow-late'),
      step('workspace', '2.18-ws-1'),
      step('workspace', '2.18-ws-2'),
      step('fast-instance', '2.19-fast'),
      step('workspace', '2.19-ws'),
    ];

    // Last attempted step is a 2.18 workspace command: the cursor is the
    // start of that version's workspace segment.
    const result = selectSkippedInstanceSteps({
      sequence,
      cursor: 5,
      completedInstanceStepNames: new Set(['2.17-fast', '2.18-fast-1']),
    });

    expect(namesOf(result)).toEqual(['2.18-fast-late', '2.18-slow-late']);
  });

  it('should keep sequence order across several earlier versions', () => {
    const sequence = [
      step('fast-instance', '1-fast'),
      step('fast-instance', '1-fast-missing'),
      step('workspace', '1-ws'),
      step('fast-instance', '2-fast'),
      step('slow-instance', '2-slow-missing'),
      step('workspace', '2-ws'),
      step('fast-instance', '3-fast'),
    ];

    const result = selectSkippedInstanceSteps({
      sequence,
      cursor: 6,
      completedInstanceStepNames: new Set(['1-fast', '2-fast']),
    });

    expect(namesOf(result)).toEqual(['1-fast-missing', '2-slow-missing']);
  });

  it('should never select steps at or after the cursor', () => {
    const sequence = [
      step('fast-instance', 'done'),
      step('workspace', 'ws'),
      step('fast-instance', 'at-cursor'),
      step('slow-instance', 'after-cursor'),
    ];

    const result = selectSkippedInstanceSteps({
      sequence,
      cursor: 2,
      completedInstanceStepNames: new Set(['done']),
    });

    expect(result).toEqual([]);
  });

  it('should never select workspace steps', () => {
    const sequence = [
      step('fast-instance', 'done'),
      step('workspace', 'ws-never-completed'),
      step('fast-instance', 'missing'),
      step('workspace', 'ws-2'),
    ];

    const result = selectSkippedInstanceSteps({
      sequence,
      cursor: 3,
      completedInstanceStepNames: new Set(['done']),
    });

    expect(namesOf(result)).toEqual(['missing']);
  });

  it('should treat steps before the first completed instance step as pre-registry history', () => {
    const sequence = [
      step('fast-instance', 'legacy-fast'),
      step('workspace', 'legacy-ws'),
      step('fast-instance', 'first-recorded'),
      step('fast-instance', 'missing'),
      step('workspace', 'ws'),
    ];

    const result = selectSkippedInstanceSteps({
      sequence,
      cursor: 4,
      completedInstanceStepNames: new Set(['first-recorded']),
    });

    expect(namesOf(result)).toEqual(['missing']);
  });

  it('should select nothing when no instance step was ever completed', () => {
    const sequence = [step('fast-instance', 'a'), step('workspace', 'ws')];

    expect(
      selectSkippedInstanceSteps({
        sequence,
        cursor: 1,
        completedInstanceStepNames: new Set(),
      }),
    ).toEqual([]);
  });
});
