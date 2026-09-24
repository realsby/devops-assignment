const { SSMClient, GetParametersByPathCommand } = require("@aws-sdk/client-ssm");

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
}

module.exports = { loadSsmParams };
