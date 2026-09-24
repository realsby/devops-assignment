const { SSMClient, GetParametersByPathCommand } = require("@aws-sdk/client-ssm");

const REFRESH_INTERVAL_MS = 5 * 60 * 1000;
let lastLoadedAt = 0;

// Cold-start only: when SSM_PARAMETER_PATH is set (Lambda), pulls every
// parameter under that path into process.env before anything else reads
// it. Local/compose runs never set this var, so plain env vars keep
// working exactly as before — this module is a no-op there, and stays
// the only place that touches AWS.
async function loadSsmParams() {
  const path = process.env.SSM_PARAMETER_PATH;
  if (!path) return;

  const client = new SSMClient({});
  let nextToken;
  do {
    const result = await client.send(
      new GetParametersByPathCommand({
        Path: path,
        WithDecryption: true,
        Recursive: true,
        NextToken: nextToken,
      })
    );
    for (const param of result.Parameters || []) {
      const name = param.Name.slice(path.length).replace(/^\//, "");
      if (name) process.env[name] = param.Value;
    }
    nextToken = result.NextToken;
  } while (nextToken);

  lastLoadedAt = Date.now();
}

// Lets a revoked token take effect without a
// redeploy: a warm Lambda re-pulls SSM once its copy is more than 5
// minutes old, instead of only ever reading it once at cold start. Called
// from the auth middleware, not on a timer — an idle function doesn't
// pay for it, and the check itself (one Date.now() comparison) costs
// nothing on the requests that don't trigger a refresh.
async function refreshSsmParamsIfStale() {
  if (!process.env.SSM_PARAMETER_PATH) return;
  if (Date.now() - lastLoadedAt < REFRESH_INTERVAL_MS) return;
  await loadSsmParams();
}

module.exports = { loadSsmParams, refreshSsmParamsIfStale };
