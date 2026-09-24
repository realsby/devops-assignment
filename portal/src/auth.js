const crypto = require("crypto");
const { refreshSsmParamsIfStale } = require("./load_ssm_params");

// API_TOKENS: comma-separated "name:sha256hex" pairs, e.g.
//   care-team:9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08
// Named tokens so a lookup is attributable to a person, not a shared secret.
function parseTokens(raw) {
  const tokens = new Map();
  for (const entry of String(raw || "").split(",")) {
    const trimmed = entry.trim();
    if (!trimmed) continue;
    const sep = trimmed.indexOf(":");
    if (sep === -1) continue;
    const name = trimmed.slice(0, sep).trim();
    const hash = trimmed.slice(sep + 1).trim().toLowerCase();
    if (!name || !/^[0-9a-f]{64}$/.test(hash)) continue;
    tokens.set(name, Buffer.from(hash, "hex"));
  }
  return tokens;
}

// Middleware factory: checks `Authorization: Bearer <token>` against the
// configured token hashes with a constant-time comparison, and sets
// req.actor to the matched name on success.
//
// Re-parses process.env.API_TOKENS on every request instead of once at
// startup — cheap for a handful of entries, and it's what makes a token
// revoked via SSM (see load_ssm_params.js's 5-minute refresh) actually
// take effect without redeploying. Locally/in tests SSM_PARAMETER_PATH
// is never set, so the refresh is a no-op and this just re-reads the
// same env var each time.
function requireAuth() {
  return async (req, res, next) => {
    await refreshSsmParamsIfStale();
    const tokens = parseTokens(process.env.API_TOKENS);

    const header = req.get("authorization") || "";
    const match = /^Bearer (.+)$/.exec(header);
    if (!match) {
      return res.status(401).json({ error: "unauthorized" });
    }
    const presented = crypto.createHash("sha256").update(match[1]).digest();
    for (const [name, expected] of tokens) {
      if (
        presented.length === expected.length &&
        crypto.timingSafeEqual(presented, expected)
      ) {
        req.actor = name;
        return next();
      }
    }
    return res.status(401).json({ error: "unauthorized" });
  };
}

module.exports = { parseTokens, requireAuth };
