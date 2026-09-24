const { Pool } = require("pg");

// Local default only. Everywhere else sets DATABASE_URL explicitly.
// sslmode (e.g. for Neon) lives in the URL itself — pg parses it.
const DEFAULT_LOCAL_URL = "postgresql://postgres:postgres@127.0.0.1:5432/wellis";

const pool = new Pool({
  connectionString: process.env.DATABASE_URL || DEFAULT_LOCAL_URL,
  // Lambda will set this low (one connection per concurrent invocation
  // adds up fast); local/dev defaults to 5.
  max: Number(process.env.PG_POOL_MAX || 5),
});

// Neon (and similar scale-to-zero providers) can drop idle connections
// out from under the pool. pg emits 'error' on the pool for that, and an
// EventEmitter 'error' with no listener crashes the process — so this
// isn't optional. Log it and carry on; the pool reconnects on next use.
pool.on("error", (err) => {
  console.error(JSON.stringify({ level: "error", message: `pg pool error: ${err.message}` }));
});

module.exports = { pool };
