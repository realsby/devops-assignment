const express = require("express");
const { pool } = require("./db");
const { requireAuth } = require("./auth");

const app = express();
app.use(express.json());

// Wraps an async route handler so a rejected promise reaches the error
// middleware instead of crashing the process (Express 4 doesn't do this
// on its own).
const asyncHandler = (fn) => (req, res, next) => {
  Promise.resolve(fn(req, res, next)).catch(next);
};

// One JSON line per request. Path only, never the query string (that's
// where the patient email lives) or the body.
//
// Uses req.originalUrl, not req.path: a mounted middleware that responds
// without calling next() (e.g. a 401 from requireAuth below) leaves
// req.url/req.path rewritten relative to its mount point for the rest of
// the request, which would otherwise log "/patients" instead of
// "/api/patients". originalUrl is set once and never rewritten.
app.use((req, res, next) => {
  const start = process.hrtime.bigint();
  const path = req.originalUrl.split("?")[0];
  res.on("finish", () => {
    const duration_ms = Number(process.hrtime.bigint() - start) / 1e6;
    console.log(
      JSON.stringify({
        method: req.method,
        path,
        status: res.statusCode,
        duration_ms: Math.round(duration_ms),
        actor: req.actor || null,
      })
    );
  });
  next();
});

// No auth, no DB query — this is what the uptime check hits, and it must
// not keep a scale-to-zero DB warm.
app.get("/healthz", (_req, res) => {
  res.status(200).json({ ok: true });
});

app.use("/api", requireAuth());

// Ops summary: how many patients, how many reminders waiting.
app.get(
  "/api/summary",
  asyncHandler(async (_req, res) => {
    const patients = await pool.query("SELECT count(*)::int AS n FROM patients");
    const queued = await pool.query(
      "SELECT count(*)::int AS n FROM reminders WHERE status = 'queued'"
    );
    res.json({
      patients: patients.rows[0].n,
      queued_reminders: queued.rows[0].n,
    });
  })
);

// Look a patient up by email. Used by the care team to find someone fast.
app.get(
  "/api/patients",
  asyncHandler(async (req, res) => {
    const email = req.query.email || "";
    const result = await pool.query(
      "SELECT id, full_name, email, dob FROM patients WHERE email = $1",
      [email]
    );
    // Audit line: who looked up what, and how many rows came back — never
    // the email or the row data itself.
    console.log(
      JSON.stringify({
        event: "patient_lookup",
        actor: req.actor,
        results: result.rows.length,
      })
    );
    res.json(result.rows);
  })
);

function isPositiveInt(value) {
  return Number.isInteger(value) && value > 0;
}

function isValidChannel(value) {
  return value === "email" || value === "sms";
}

function isValidIsoDate(value) {
  if (typeof value !== "string" || !value) return false;
  return !Number.isNaN(new Date(value).getTime());
}

// Queue a reminder for a patient.
app.post(
  "/api/reminders",
  asyncHandler(async (req, res) => {
    const { patient_id, channel, send_at } = req.body || {};
    if (!isPositiveInt(patient_id)) {
      return res.status(400).json({ error: "patient_id must be a positive integer" });
    }
    if (!isValidChannel(channel)) {
      return res.status(400).json({ error: "channel must be 'email' or 'sms'" });
    }
    if (!isValidIsoDate(send_at)) {
      return res.status(400).json({ error: "send_at must be a valid ISO date" });
    }
    const result = await pool.query(
      "INSERT INTO reminders (patient_id, channel, send_at, status) VALUES ($1, $2, $3, 'queued') RETURNING id",
      [patient_id, channel, send_at]
    );
    res.json({ id: result.rows[0].id });
  })
);

// Error middleware: never lets a handler failure crash the process, never
// logs row data — just the error message.
// eslint-disable-next-line no-unused-vars
app.use((err, _req, res, _next) => {
  console.error(JSON.stringify({ level: "error", message: err.message }));
  res.status(500).json({ error: "internal_error" });
});

module.exports = app;
