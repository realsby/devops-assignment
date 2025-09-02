const { Pool } = require("pg");

// Connects as the postgres superuser. It was the account that already
// existed when we set the box up, and everything worked, so it stayed.
const pool = new Pool({
  host: process.env.DB_HOST || "127.0.0.1",
  port: Number(process.env.DB_PORT || 5432),
  user: process.env.DB_USER || "postgres",
  password: process.env.DB_PASSWORD || "postgres",
  database: process.env.DB_NAME || "wellis",
  max: 10,
});

module.exports = { pool };
