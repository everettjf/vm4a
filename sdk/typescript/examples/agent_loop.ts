/**
 * End-to-end example: spawn a base VM, fork per task, run code, reset on failure.
 *
 * Prereq: `vm4a serve --port 7777` is running.
 *
 * Run with: `node --loader ts-node/esm examples/agent_loop.ts` (or build first).
 */

import { Client } from "../src/client.js";

async function main(): Promise<number> {
  const c = new Client();
  console.log("server:", await c.health());

  const storage = "/tmp/vm4a";
  const baseName = "py-dev";
  const snapshot = `${storage}/${baseName}/clean.vzstate`;

  // 1. First-time bootstrap.
  const existing = await c.list(storage);
  if (!existing.some((vm) => vm.name === baseName)) {
    console.log("spawning base VM (pulls image, waits for SSH)...");
    const vm = await c.spawn(baseName, {
      from: "ghcr.io/yourorg/python-dev-arm64:latest",
      storage,
      saveOnStop: snapshot,
      waitSsh: true,
      waitTimeout: 180,
      allowDomains: ["pypi.org", "files.pythonhosted.org"],
    });
    console.log(`  base VM ready: ${vm.id} at ${vm.ip}`);
    await c.exec(vm.path, ["bash", "-lc", "apt-get update && apt-get install -y ripgrep"]);
    await c.stop(vm.path);
  }

  // 2. Per-task fork.
  const taskPath = `${storage}/task-demo-001`;
  const fork = await c.fork(`${storage}/${baseName}`, taskPath, {
    fromSnapshot: snapshot,
    autoStart: true,
    waitSsh: true,
  });
  console.log(`  task VM up at ${fork.ip}`);

  // 3. Run code directly (no manual cp + exec).
  const out = await c.runCode(taskPath, "python", "import platform; print('hello from', platform.node())");
  console.log(`  exit=${out.exitCode} stdout=${JSON.stringify(out.stdout)}`);

  // 4. Reset on failure.
  if (out.exitCode !== 0) {
    await c.reset(taskPath, snapshot, { waitIp: true });
  }

  await c.stop(taskPath);
  return out.exitCode;
}

main().then((code) => process.exit(code));
