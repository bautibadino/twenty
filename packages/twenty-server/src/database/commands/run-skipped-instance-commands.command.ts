import { Logger } from '@nestjs/common';

import chalk from 'chalk';
import { Command, CommandRunner, Option } from 'nest-commander';

import { InstanceCommandRunnerService } from 'src/engine/core-modules/upgrade/services/instance-command-runner.service';
import { UpgradeMigrationService } from 'src/engine/core-modules/upgrade/services/upgrade-migration.service';
import { UpgradeSequenceReaderService } from 'src/engine/core-modules/upgrade/services/upgrade-sequence-reader.service';
import { UpgradeSequenceRunnerService } from 'src/engine/core-modules/upgrade/services/upgrade-sequence-runner.service';
import { UpgradeStatusService } from 'src/engine/core-modules/upgrade/services/upgrade-status.service';
import { selectSkippedInstanceSteps } from 'src/engine/core-modules/upgrade/utils/select-skipped-instance-steps.util';
import { WorkspaceVersionService } from 'src/engine/workspace-manager/workspace-version/services/workspace-version.service';
import { isDefined } from 'twenty-shared/utils';

type RunSkippedInstanceCommandsOptions = {
  dryRun?: boolean;
};

// `upgrade` resumes from the segment of the last attempted step, so an instance
// command added to an already-released version after a database moved past it
// is never run. This command applies those commands, and only those, before
// `upgrade` starts.
@Command({
  name: 'run-skipped-instance-commands',
  description:
    'Run instance commands positioned before the upgrade cursor that were never completed',
})
export class RunSkippedInstanceCommandsCommand extends CommandRunner {
  private readonly logger = new Logger(RunSkippedInstanceCommandsCommand.name);

  constructor(
    private readonly workspaceVersionService: WorkspaceVersionService,
    private readonly upgradeSequenceReaderService: UpgradeSequenceReaderService,
    private readonly upgradeSequenceRunnerService: UpgradeSequenceRunnerService,
    private readonly instanceCommandRunnerService: InstanceCommandRunnerService,
    private readonly upgradeMigrationService: UpgradeMigrationService,
    private readonly upgradeStatusService: UpgradeStatusService,
  ) {
    super();
  }

  @Option({
    flags: '-d, --dry-run',
    description:
      'List the instance commands that would run without running them',
    required: false,
  })
  parseDryRun(): boolean {
    return true;
  }

  async run(
    _passedParams: string[],
    options: RunSkippedInstanceCommandsOptions,
  ): Promise<void> {
    try {
      const lastAttemptedInstanceCommand =
        await this.upgradeMigrationService.getLastAttemptedInstanceCommand();

      if (!isDefined(lastAttemptedInstanceCommand)) {
        this.logger.log('No upgrade history found, nothing to do');

        return;
      }

      const provisionedWorkspaceIds =
        await this.workspaceVersionService.getProvisionedWorkspaceIds();

      const sequence = this.upgradeSequenceReaderService.getUpgradeSequence();

      const cursor = await this.upgradeSequenceRunnerService.resolveStartCursor(
        {
          sequence,
          allProvisionedWorkspaceIds: provisionedWorkspaceIds,
        },
      );

      const completedInstanceStepNames = new Set<string>();

      for (const step of sequence.slice(0, cursor)) {
        if (step.kind === 'workspace') {
          continue;
        }

        const isCompleted =
          await this.upgradeMigrationService.isLastAttemptCompleted({
            name: step.name,
            workspaceId: null,
          });

        if (isCompleted) {
          completedInstanceStepNames.add(step.name);
        }
      }

      const skippedSteps = selectSkippedInstanceSteps({
        sequence,
        cursor,
        completedInstanceStepNames,
      });

      if (skippedSteps.length === 0) {
        this.logger.log('No skipped instance commands, nothing to do');

        return;
      }

      this.logger.log(
        `Skipped instance commands (${skippedSteps.length}): ${skippedSteps
          .map((step) => `${step.name} [${step.kind}]`)
          .join(', ')}`,
      );

      if (options.dryRun) {
        this.logger.log('Dry run, nothing executed');

        return;
      }

      for (const step of skippedSteps) {
        if (step.kind === 'workspace') {
          continue;
        }

        const result =
          step.kind === 'fast-instance'
            ? await this.instanceCommandRunnerService.runFastInstanceCommand({
                command: step.command,
                name: step.name,
              })
            : await this.instanceCommandRunnerService.runSlowInstanceCommand({
                command: step.command,
                name: step.name,
                skipDataMigration: provisionedWorkspaceIds.length === 0,
              });

        if (result.status === 'failed') {
          throw result.error;
        }
      }

      this.logger.log(chalk.green('Skipped instance commands completed'));
    } catch (error) {
      this.logger.error(
        chalk.red(
          `Skipped instance commands failed: ${
            error instanceof Error ? error.message : String(error)
          }`,
        ),
      );
      throw error;
    } finally {
      await this.safeInvalidateUpgradeStatusCache();
    }
  }

  private async safeInvalidateUpgradeStatusCache(): Promise<void> {
    try {
      await this.upgradeStatusService.invalidateInstanceAndAllWorkspacesStatus();
    } catch (error) {
      this.logger.warn(
        `Failed to invalidate upgrade-status cache: ${
          error instanceof Error ? error.message : String(error)
        }`,
      );
    }
  }
}
