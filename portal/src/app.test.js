// Integration tests against a real Postgres.
//
// The app itself connects via DATABASE_URL — under `make test` that's
// the portal_app role, the same one a real deploy runs under. Fixture
// setup/teardown use ADMIN_DATABASE_URL (the owner) instead, since
// portal_app can't insert into patients or delete reminders — which is
// the point: running the app as its real role exercises the grants in
// migrations/004_app_role_grants.sql instead of assuming they're right.
//
// `make test` sets all of this up. For an ad-hoc run without it, falls
// back to a throwaway container with 001, 002 and 004 applied and
// db/init/01_roles.sql run by hand:
//   docker run -d -p 127.0.0.1:55432:5432 \
//     -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=wellis postgres:18-alpine
const { test, before, after } = require("node:test");
const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const { Pool } = require("pg");

const TOKEN = process.env.TEST_TOKEN || "test-token";
const WRONG_TOKEN = "wrong-token";

process.env.API_TOKENS =
  process.env.API_TOKENS || `tester:${crypto.createHash("sha256").update(TOKEN).digest("hex")}`;
process.env.DATABASE_URL =
  process.env.DATABASE_URL || "postgresql://postgres:postgres@127.0.0.1:55432/wellis";

const ADMIN_DATABASE_URL = process.env.ADMIN_DATABASE_URL || process.env.DATABASE_URL;

const app = require("./app");
const { pool } = require("./db"); // the app's own pool — connects as whatever DATABASE_URL says
const adminPool = new Pool({ connectionString: ADMIN_DATABASE_URL });

let server;
let baseUrl;
let patientEmail;
let patientId;

before(async () => {
  server = app.listen(0);
  await new Promise((resolve) => server.once("listening", resolve));
  baseUrl = `http://127.0.0.1:${server.address().port}`;

  patientEmail = `test.patient.${Date.now()}@example.com`;
  const inserted = await adminPool.query(
    "INSERT INTO patients (full_name, email, dob) VALUES ($1, $2, $3) RETURNING id",
    ["Test Patient", patientEmail, "1990-01-01"]
  );
  patientId = inserted.rows[0].id;
});

after(async () => {
  await adminPool.query("DELETE FROM reminders WHERE patient_id = $1", [patientId]);
  await adminPool.query("DELETE FROM patients WHERE id = $1", [patientId]);
  await new Promise((resolve) => server.close(resolve));
  await adminPool.end();
  await pool.end();
});

test("GET /healthz needs no auth", async () => {
  const res = await fetch(`${baseUrl}/healthz`);
  assert.equal(res.status, 200);
});

test("GET /api/patients without a token is 401", async () => {
  const res = await fetch(`${baseUrl}/api/patients?email=${encodeURIComponent(patientEmail)}`);
  assert.equal(res.status, 401);
});

test("GET /api/patients with a wrong token is 401", async () => {
  const res = await fetch(`${baseUrl}/api/patients?email=${encodeURIComponent(patientEmail)}`, {
    headers: { Authorization: `Bearer ${WRONG_TOKEN}` },
  });
  assert.equal(res.status, 401);
});

test("SQL injection payload returns an empty array, not an error or every row", async () => {
  const res = await fetch(
    `${baseUrl}/api/patients?email=${encodeURIComponent("x' OR '1'='1")}`,
    { headers: { Authorization: `Bearer ${TOKEN}` } }
  );
  assert.equal(res.status, 200);
  assert.deepEqual(await res.json(), []);
});

test("normal lookup returns the matching patient", async () => {
  const res = await fetch(`${baseUrl}/api/patients?email=${encodeURIComponent(patientEmail)}`, {
    headers: { Authorization: `Bearer ${TOKEN}` },
  });
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.length, 1);
  assert.equal(body[0].email, patientEmail);
  assert.equal(body[0].full_name, "Test Patient");
});

test("POST /api/reminders rejects invalid input with 400", async () => {
  const res = await fetch(`${baseUrl}/api/reminders`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${TOKEN}` },
    body: JSON.stringify({ patient_id: -1, channel: "carrier-pigeon", send_at: "not-a-date" }),
  });
  assert.equal(res.status, 400);
});

test("POST /api/reminders queues a valid reminder", async () => {
  const res = await fetch(`${baseUrl}/api/reminders`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${TOKEN}` },
    body: JSON.stringify({
      patient_id: patientId,
      channel: "email",
      send_at: new Date().toISOString(),
    }),
  });
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.ok(body.id);
});
