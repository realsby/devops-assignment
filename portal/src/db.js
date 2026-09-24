const { Pool } = require("pg");

// Local default only. Everywhere else sets DATABASE_URL explicitly.
// sslmode (e.g. for Neon) lives in the URL itself — pg parses it.
const DEFAULT_LOCAL_URL = "postgresql://postgres:postgres@127.0.0.1:5432/wellis";

const pool = new Pool({
  connectionString: process.env.DATABASE_URL || DEFAULT_LOCAL_URL,
  max: 10,
});

module.exports = { pool };
