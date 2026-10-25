// Stand-in for podman used by the unit tests.
//
// Records every call (arguments plus the environment variables p4a is
// expected to set) as one JSON line in $FAKE_PODMAN_DIR/calls.jsonl, then
// replies with canned output from the rules the test set up with
// `fake_podman` (see test/helpers.bash).
//
// It runs under node because node is a native program on Windows: Git Bash
// applies its path conversion to node's arguments exactly as it would to
// the real podman.exe, so the recorded arguments are what Podman would see.
const fs = require("fs");
const path = require("path");

const dir = process.env.FAKE_PODMAN_DIR;
if (!dir) {
  console.error("fake podman: FAKE_PODMAN_DIR is not set");
  process.exit(99);
}

const args = process.argv.slice(2);
const env = {};
for (const name of ["CONTAINERS_MACHINE_PROVIDER", "MSYS_NO_PATHCONV", "CONTAINERS_CONF_OVERRIDE"]) {
  if (name in process.env) env[name] = process.env[name];
}
// Capture the override file's contents now; p4a may delete it afterwards.
let conf = null;
if (env.CONTAINERS_CONF_OVERRIDE) {
  try {
    conf = fs.readFileSync(env.CONTAINERS_CONF_OVERRIDE, "utf8");
  } catch {
    conf = null;
  }
}
fs.appendFileSync(path.join(dir, "calls.jsonl"), JSON.stringify({ args, env, conf }) + "\n");

// The last rule whose prefix matches the start of the arguments wins.
const rulesDir = path.join(dir, "rules");
let rule = null;
if (fs.existsSync(rulesDir)) {
  const ids = fs.readdirSync(rulesDir).map(Number).sort((a, b) => a - b);
  for (const id of ids) {
    const ruleDir = path.join(rulesDir, String(id));
    const prefix = fs.readFileSync(path.join(ruleDir, "prefix"), "utf8").split(" ").filter(Boolean);
    if (prefix.every((word, i) => args[i] === word)) rule = ruleDir;
  }
}

const read = (name) => {
  const file = rule && path.join(rule, name);
  return file && fs.existsSync(file) ? fs.readFileSync(file, "utf8") : null;
};
const stdout = read("stdout");
const stderr = read("stderr");
if (stdout !== null) process.stdout.write(stdout);
if (stderr !== null) process.stderr.write(stderr);
const remove = read("remove");
if (remove !== null) fs.rmSync(remove.trim(), { force: true });
process.exitCode = Number(read("exit") ?? 0);
