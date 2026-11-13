// Scenario result ordering is separate from browser/cloud fixtures so faults can
// be exercised without launching a browser or performing external operations.
export async function recordScenario(results, name, { exercise, cleanup, verify }) {
  let detail;
  const failures = [];
  try {
    detail = await exercise();
  } catch (error) {
    failures.push({ phase: 'exercise', error });
  }
  try {
    await cleanup();
  } catch (error) {
    failures.push({ phase: 'cleanup', error });
  }
  if (failures.length === 0) {
    try {
      await verify();
    } catch (error) {
      failures.push({ phase: 'verify', error });
    }
  }
  if (failures.length) {
    // Do not persist exception messages, stacks or unverified success details.
    results.push({ name, status: 'FAIL', failed_phases: failures.map(failure => failure.phase) });
    if (failures.length === 1) throw failures[0].error;
    throw new AggregateError(failures.map(failure => failure.error), 'Browser scenario failed');
  }
  results.push({ ...detail, name, status: 'PASS' });
}

export async function closeScenario(steps) {
  const failures = [];
  for (const close of steps) {
    try {
      await close();
    } catch (error) {
      failures.push(error);
    }
  }
  if (failures.length) throw new AggregateError(failures, 'Browser scenario cleanup failed');
}
