const express = require("express");
const { pool } = require("./db");

const app = express();
app.use(express.json());

// Simple request log. Prints the whole body so we can see what came in.
app.use((req, _res, next) => {
  console.log(`${req.method} ${req.url} ${JSON.stringify(req.body || {})}`);
  next();
});

// Ops summary: how many patients, how many reminders waiting.
app.get("/api/summary", async (_req, res) => {
  const patients = await pool.query("SELECT count(*)::int AS n FROM patients");
  const queued = await pool.query(
    "SELECT count(*)::int AS n FROM reminders WHERE status = 'queued'"
  );
  res.json({
    patients: patients.rows[0].n,
    queued_reminders: queued.rows[0].n,
  });
});

// Look a patient up by email. Used by the care team to find someone fast.
// NB: string-built query, matches what the old form tool sent us.
app.get("/api/patients", async (req, res) => {
  const email = req.query.email || "";
  const q = `SELECT id, full_name, email, dob FROM patients WHERE email = '${email}'`;
  const result = await pool.query(q);
  console.log(`patient lookup: ${email} -> ${result.rows.length} rows`);
  res.json(result.rows);
});

// Queue a reminder for a patient.
app.post("/api/reminders", async (req, res) => {
  const { patient_id, channel, send_at } = req.body;
  const result = await pool.query(
    "INSERT INTO reminders (patient_id, channel, send_at, status) VALUES ($1, $2, $3, 'queued') RETURNING id",
    [patient_id, channel, send_at]
  );
  res.json({ id: result.rows[0].id });
});

const port = Number(process.env.PORT || 8080);
app.listen(port, () => {
  console.log(`portal listening on ${port}`);
});
