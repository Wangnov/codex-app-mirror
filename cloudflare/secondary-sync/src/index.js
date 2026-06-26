import { WorkflowEntrypoint } from "cloudflare:workers";
import {
  NonRetryableMirrorError,
  buildObjectPlan,
  cleanupStageObjects,
  commitObjectToAliases,
  commitOrder,
  decoratePlanWithStage,
  discoverSourceManifest,
  handleApiRequest,
  pruneStaleLatestMacObjects,
  reconcileSync,
  uploadObjectToStage,
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
  timeout: "5 minutes",
};
const HOUSEKEEPING_STEP = {
  retries: { limit: 3, delay: "10 seconds", backoff: "linear" },
  timeout: "10 minutes",
};
const RuntimeNonRetryableError = globalThis.NonRetryableError || Error;

export class SecondaryMirrorWorkflow extends WorkflowEntrypoint {
  async run(event, step) {
    const payload = event.payload || {};

    const source = await step.do("discover source manifest", DISCOVERY_STEP, () =>
      nonRetryableGuard(() => discoverSourceManifest(this.env, payload.releaseTag || "")),
    );

    const plan = decoratePlanWithStage(
      buildObjectPlan(source.manifest, source.releaseTag),
      event.instanceId,
      this.env,
    );

    const uploadResults = [];
    for (const item of plan.items) {
      uploadResults.push(
        await step.do(stepName("upload", item), UPLOAD_STEP, () =>
          nonRetryableGuard(() =>
            uploadObjectToStage(this.env, item, {
              forceUpload: Boolean(payload.force),
            }),
          ),
        ),
      );
    }

    const commitResults = [];
    for (const item of commitOrder(plan.items)) {
      commitResults.push(
        await step.do(stepName("commit", item), COMMIT_STEP, () =>
          nonRetryableGuard(() => commitObjectToAliases(this.env, item)),
        ),
      );
    }

    const pruneResult = await step.do("prune stale Sparkle archives", HOUSEKEEPING_STEP, () =>
      nonRetryableGuard(() => pruneStaleLatestMacObjects(this.env, plan.keepLatestMacKeys)),
    );

    const cleanupResult = await step.do("cleanup secondary staging objects", HOUSEKEEPING_STEP, () =>
      nonRetryableGuard(() => cleanupStageObjects(this.env, plan.items)),
    );

    return {
      releaseTag: source.releaseTag,
      manifestSha256: source.manifestSha256,
      stagePrefix: plan.stagePrefix,
      uploaded: uploadResults.length,
      committed: commitResults.reduce((count, result) => count + result.aliases.length, 0),
      pruned: pruneResult.pruned.length,
      cleaned: cleanupResult.deleted.length,
      completedAt: new Date().toISOString(),
    };
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
