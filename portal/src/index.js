const { loadSsmParams } = require("./load_ssm_params");

// app.js (and its own requires — db.js, auth.js) read DATABASE_URL /
// API_TOKENS / etc. from process.env at require-time, so the SSM load
// has to finish before that require happens, not just before listen().
async function main() {
  await loadSsmParams();
  const app = require("./app");
  const port = Number(process.env.PORT || 8080);
  app.listen(port, () => {
    console.log(`portal listening on ${port}`);
  });
}

main().catch((err) => {
  console.error(JSON.stringify({ level: "error", message: `startup failed: ${err.message}` }));
  process.exit(1);
});
