/// Fixture for scripts/test_storybook_e2e_parallel_contract.sh: no app, no RPC. Every test appends
/// "<ms> <pid> <name>" to $FIXTURE_TRACE so the contract can check placement and ordering;
/// FIXTURE_FAIL names a test that throws.
import { appendFileSync, existsSync } from "node:fs";
import { test, run } from "../runner";

function step(name: string, ms = 30) {
  return async () => {
    appendFileSync(process.env.FIXTURE_TRACE!, `${Date.now()} ${process.pid} ${name}\n`);
    await new Promise((r) => setTimeout(r, ms));
    if (process.env.FIXTURE_FAIL === name) throw new Error(`fixture failure: ${name}`);
  };
}

test("preflight", async () => {
  // The fake suite can finish before a newly launched shell gets scheduled.
  // Require the fake app to start before doing any work, like the real suite.
  const ready = `${process.env.ZENIT_E2E_FILE_RPC_DIR}/fixture-app-ready`;
  const deadline = Date.now() + 5000;
  while (!existsSync(ready) && Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  if (!existsSync(ready)) throw new Error("fake app did not start");
  await step("preflight", 5)();
}, { fatal: true });
for (let i = 0; i < 12; i++) test(`work ${i}`, step(`work ${i}`, 20 + i * 10));
test("timing gate", step("timing gate", 50), { serial: "fixture: measures wall time" });
test("invariant", step("invariant", 5), { final: true });

run();
