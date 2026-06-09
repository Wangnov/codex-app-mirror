const GITHUB_API_VERSION = "2022-11-28";
const USER_AGENT = "codex-app-mirror-cloudflare-cron";

export default {
  async scheduled(controller, env) {
    const result = await dispatchWorkflow(controller, env);
    console.log(JSON.stringify(result));
    return result;
  },
};

async function dispatchWorkflow(controller, env) {
  if (!env.GITHUB_TOKEN) {
    throw new Error("GITHUB_TOKEN secret is not configured.");
  }

  const owner = env.GITHUB_OWNER || "Wangnov";
  const repo = env.GITHUB_REPO || "codex-app-mirror";
  const workflow = env.GITHUB_WORKFLOW || "mirror.yml";
  const ref = env.GITHUB_REF || "main";
  const forceRelease = env.GITHUB_FORCE_RELEASE || "false";

  const targets = [
    { owner, repo, workflow, ref },
    {
      owner: "Wangnov",
      repo: "agents-cli-mirror",
      workflow: "mirror.yml",
      ref: "main",
    },
  ];

  const settled = await Promise.allSettled(
    targets.map((target) => dispatchWorkflowTarget(controller, env, target, forceRelease)),
  );

  const results = settled.map((entry, index) => {
    if (entry.status === "fulfilled") {
      return entry.value;
    }

    return (
      entry.reason.result || {
        event: "github_workflow_dispatch",
        cron: controller.cron,
        ...targets[index],
        force_release: forceRelease,
        ok: false,
        error: entry.reason.message,
        at: new Date().toISOString(),
      }
    );
  });

  const succeeded = results.filter((result) => result.ok).length;
  const failed = results.length - succeeded;
  const result = {
    event: "github_workflow_dispatch_batch",
    cron: controller.cron,
    ok: succeeded > 0,
    succeeded,
    failed,
    targets: results,
    at: new Date().toISOString(),
  };

  if (!result.ok) {
    console.error(JSON.stringify(result));
    throw new Error("All GitHub workflow dispatches failed.");
  }

  if (failed > 0) {
    console.error(JSON.stringify(result));
  }

  return result;
}

async function dispatchWorkflowTarget(controller, env, target, forceRelease) {
  const { owner, repo, workflow, ref } = target;
  const url = new URL(
    `https://api.github.com/repos/${encodeURIComponent(owner)}/${encodeURIComponent(repo)}/actions/workflows/${encodeURIComponent(workflow)}/dispatches`,
  );

  const response = await fetch(url, {
    method: "POST",
    headers: {
      Accept: "application/vnd.github+json",
      Authorization: `Bearer ${env.GITHUB_TOKEN}`,
      "Content-Type": "application/json",
      "User-Agent": USER_AGENT,
      "X-GitHub-Api-Version": GITHUB_API_VERSION,
    },
    body: JSON.stringify({
      ref,
      inputs: {
        force_release: forceRelease,
      },
    }),
  });

  const result = {
    event: "github_workflow_dispatch",
    cron: controller.cron,
    owner,
    repo,
    workflow,
    ref,
    force_release: forceRelease,
    status: response.status,
    ok: response.ok,
    at: new Date().toISOString(),
  };

  if (!response.ok) {
    result.body = await response.text();
    console.error(JSON.stringify(result));
    const error = new Error(`GitHub workflow dispatch failed with HTTP ${response.status}.`);
    error.result = result;
    throw error;
  }

  console.log(JSON.stringify(result));
  return result;
}
