import { WorkflowEntrypoint } from "cloudflare:workers";
import { NonRetryableError } from "cloudflare:workflows";
import {
  NonRetryableMirrorError,
  aliasBackupKeys,
  buildObjectPlan,
  cleanupRollbackBackups,
  cleanupStageObjects,
  commitOrder,
  commitSingleAlias,
  decoratePlanWithStage,
  deleteStaleAliasObjects,
  discoverSourceManifest,
  handleApiRequest,
  isSupersededError,
  pruneAbandonedStageObjects,
  pruneStaleLatestMacObjects,
  reconcileSync,
  recordSwitchoverCommittedCheckpoint,
  rollbackCommittedAliases,
  uploadObjectToStage,
  verifyPriorSwitchoverCheckpoint,
  verifySourceManifestCurrent,
} from "./core.js";

const DISCOVERY_STEP = {
  retries: { limit: 2, delay: "10 seconds", backoff: "linear" },
  timeout: "2 minutes",
};
const UPLOAD_STEP = {
  retries: { limit: 3, delay: "30 seconds", backoff: "exponential" },
  timeout: "30 minutes",
};
const COMMIT_STEP = {
  retries: { limit: 3, delay: "10 seconds", backoff: "linear" },
  timeout: "15 minutes",
};
const HOUSEKEEPING_STEP = {
  retries: { limit: 3, delay: "10 seconds", backoff: "linear" },
  timeout: "10 minutes",
};
const RuntimeNonRetryableError = NonRetryableError || globalThis.NonRetryableError || Error;

export class SecondaryMirrorWorkflow extends WorkflowEntrypoint {
  async run(event, step) {
    const payload = event.payload || {};

    const source = await step.do("discover source manifest", DISCOVERY_STEP, () =>
      nonRetryableGuard(() =>
        discoverSourceManifest(
          this.env,
          payload.releaseTag || "",
          payload.manifestSha256 || "",
          {
            instanceId: event.instanceId,
            claimPointer: true,
          },
        ),
      ),
    );

    let plan = decoratePlanWithStage(
      {
        releaseTag: source.releaseTag,
        items: [],
        staleAliasKeys: [],
        keepLatestMacKeys: [],
      },
      event.instanceId,
      this.env,
    );
    let abandonedStageResult = { deleted: [], aborted: [] };
    const committedAliases = [];
    const attemptedAliases = [];
    let commitStarted = false;
    let switchoverComplete = false;
    try {
      plan = decoratePlanWithStage(
        buildObjectPlan(source.manifest, source.releaseTag, {
          manifestText: source.manifestText,
          manifestSha256: source.manifestSha256,
          secondaryPrefix: this.env.SECONDARY_S3_PREFIX || "",
          publicBaseUrl: this.env.PUBLIC_BASE_URL || "",
        }),
        event.instanceId,
        this.env,
      );

      abandonedStageResult = await step.do(
        "prune abandoned secondary staging",
        HOUSEKEEPING_STEP,
        () => nonRetryableGuard(() => pruneAbandonedStageObjects(this.env, plan.stagePrefix)),
      );

      const priorCommitted = await step.do(
        "check prior switchover checkpoint",
        DISCOVERY_STEP,
        () =>
          nonRetryableGuard(() =>
            verifyPriorSwitchoverCheckpoint(this.env, source, plan, {
              instanceId: event.instanceId,
              force: Boolean(payload.force),
            }),
          ),
      );

      let uploadResults = [];
      if (priorCommitted?.completed === true) {
        switchoverComplete = true;
        committedAliases.push(...(priorCommitted.entries || []));
      } else {
        const uploadedShaById = new Map();
        for (const item of plan.items) {
          const uploadRes = await step.do(stepName("upload", item), UPLOAD_STEP, () =>
            nonRetryableGuard(() =>
              uploadObjectToStage(this.env, item, {
                forceUpload: Boolean(payload.force),
              }),
            ),
          );
          uploadResults.push(uploadRes);
          if (uploadRes?.sha256) {
            uploadedShaById.set(item.id, uploadRes.sha256);
          }
        }

        await step.do("verify source manifest still current", DISCOVERY_STEP, () =>
          nonRetryableGuard(() =>
            verifySourceManifestCurrent(this.env, source.manifestSha256, {
              instanceId: event.instanceId,
              requirePointer: true,
            }),
          ),
        );

        commitStarted = true;
        for (const item of commitOrder(plan.items)) {
          for (const aliasKey of item.aliasKeys) {
            const detKeys = aliasBackupKeys(item.stageKey, aliasKey, plan.stagePrefix);
            attemptedAliases.push({
              aliasKey,
              stageKey: item.stageKey,
              backupKey: detKeys.backupKey,
              stateKey: detKeys.stateKey,
              hadExisting: true,
              optionalIfNoState: true,
            });
            const aliasResult = await step.do(
              aliasStepName("commit", item.id, aliasKey),
              COMMIT_STEP,
              () =>
                nonRetryableGuard(() =>
                  commitSingleAlias(this.env, item.stageKey, aliasKey, {
                    keepBackup: true,
                    expectedManifestSha256: source.manifestSha256,
                    instanceId: event.instanceId,
                    stagePrefix: plan.stagePrefix,
                    force: Boolean(payload.force),
                    itemExpectedSha256: uploadedShaById.get(item.id) || item.expectedSha256 || "",
                    itemExpectedManifestSha256: item.expectedManifestSha256 || "",
                    itemExpectedChecksums: item.expectedChecksums || null,
                    itemExpectedAppcast: item.expectedAppcast || null,
                  }),
                ),
            );
            committedAliases.push(aliasResult);
          }
        }
        switchoverComplete = true;

        await step.do("record switchover committed", COMMIT_STEP, () =>
          nonRetryableGuard(() =>
            recordSwitchoverCommittedCheckpoint(this.env, plan.stagePrefix, committedAliases, {
              releaseTag: source.releaseTag,
              manifestSha256: source.manifestSha256,
              instanceId: event.instanceId,
            }),
          ),
        );
      }

      await step.do("cleanup alias rollback backups", HOUSEKEEPING_STEP, () =>
        nonRetryableGuard(() =>
          cleanupRollbackBackups(this.env, committedAliases, {
            expectedManifestSha256: source.manifestSha256,
            instanceId: event.instanceId,
            stagePrefix: plan.stagePrefix,
            purgeSupersededOrphans: true,
          }),
        ),
      );

      const staleAliasResult = await step.do("delete stale latest aliases", HOUSEKEEPING_STEP, () =>
        nonRetryableGuard(() =>
          deleteStaleAliasObjects(this.env, plan.staleAliasKeys, {
            expectedManifestSha256: source.manifestSha256,
            instanceId: event.instanceId,
          }),
        ),
      );

      const pruneResult = await step.do("prune stale Sparkle archives", HOUSEKEEPING_STEP, () =>
        nonRetryableGuard(() =>
          pruneStaleLatestMacObjects(this.env, plan.keepLatestMacKeys, {
            expectedManifestSha256: source.manifestSha256,
            instanceId: event.instanceId,
          }),
        ),
      );

      const cleanupResult = await step.do("cleanup secondary staging objects", HOUSEKEEPING_STEP, () =>
        nonRetryableGuard(() =>
          cleanupStageObjects(this.env, plan.items, plan.stagePrefix, {
            switchoverComplete: true,
            expectedManifestSha256: source.manifestSha256,
            instanceId: event.instanceId,
          }),
        ),
      );

      return {
        releaseTag: source.releaseTag,
        manifestSha256: source.manifestSha256,
        stagePrefix: plan.stagePrefix,
        abandonedStageObjectsDeleted: abandonedStageResult.deleted.length,
        abandonedMultipartUploadsAborted: abandonedStageResult.aborted.length,
        uploaded: uploadResults.length,
        committed: committedAliases.length,
        staleAliasesDeleted: staleAliasResult.deleted.length,
        pruned: pruneResult.pruned.length,
        cleaned: cleanupResult.deleted.length,
        completedAt: new Date().toISOString(),
      };
    } catch (error) {
      let rollbackFailed = false;
      if (!switchoverComplete && !isSupersededError(error)) {
        try {
          await step.do("rollback committed secondary aliases", HOUSEKEEPING_STEP, () =>
            nonRetryableGuard(() => {
              const committedSet = new Set(committedAliases.map((entry) => entry.aliasKey));
              const recoveryEntries = [
                ...committedAliases,
                ...attemptedAliases.filter((entry) => !committedSet.has(entry.aliasKey)),
              ];
              return rollbackCommittedAliases(this.env, recoveryEntries, {
                expectedManifestSha256: source.manifestSha256,
                instanceId: event.instanceId,
                stagePrefix: plan.stagePrefix,
              });
            }),
          );
        } catch (rollbackError) {
          rollbackFailed = true;
          console.error(
            JSON.stringify({
              event: "secondary_sync_group_rollback_failed",
              stagePrefix: plan.stagePrefix,
              error: rollbackError.message,
            }),
          );
        }
      }
      try {
        await step.do("cleanup failed secondary staging objects", HOUSEKEEPING_STEP, () =>
          nonRetryableGuard(() =>
            cleanupStageObjects(this.env, plan.items, plan.stagePrefix, {
              preserveBackups: rollbackFailed,
              switchoverComplete,
              expectedManifestSha256: source.manifestSha256,
              instanceId: event.instanceId,
            }),
          ),
        );
      } catch (cleanupError) {
        console.error(
          JSON.stringify({
            event: "secondary_sync_failure_cleanup_failed",
            stagePrefix: plan.stagePrefix,
            error: cleanupError.message,
          }),
        );
      }
      if (error instanceof NonRetryableMirrorError) {
        throw new RuntimeNonRetryableError(error.message, error.name);
      }
      throw error;
    }
  }
}

export default {
  async fetch(request, env) {
    try {
      return await handleApiRequest(request, env);
    } catch (error) {
      const status = error.message === "Unauthorized." ? 401 : 500;
      console.error(
        JSON.stringify({
          event: "secondary_sync_api_error",
          status,
          error: error.message,
        }),
      );
      return Response.json(
        {
          ok: false,
          error: error.message,
        },
        { status },
      );
    }
  },

  async scheduled(_controller, env, ctx) {
    ctx.waitUntil(
      reconcileSync(env, {})
        .then((result) =>
          console.log(
            JSON.stringify({
              event: "secondary_sync_scheduled_reconcile",
              ...result,
            }),
          ),
        )
        .catch((error) =>
          console.error(
            JSON.stringify({
              event: "secondary_sync_scheduled_reconcile_failed",
              error: error.message,
            }),
          ),
        ),
    );
  },
};

async function nonRetryableGuard(fn) {
  try {
    return await fn();
  } catch (error) {
    if (error instanceof NonRetryableMirrorError) {
      throw new RuntimeNonRetryableError(error.message, error.name);
    }
    throw error;
  }
}

function stepName(prefix, item) {
  const name = `${prefix} ${item.id}`;
  if (name.length <= 180) {
    return name;
  }
  return `${name.slice(0, 150)}-${item.id.length}`;
}

function aliasStepName(prefix, itemId, aliasKey) {
  const name = `${prefix} ${itemId}:${aliasKey}`;
  if (name.length <= 180) {
    return name;
  }
  return `${name.slice(0, 150)}-${aliasKey.length}`;
}
