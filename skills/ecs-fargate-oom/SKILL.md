---
name: ecs-fargate-oom-investigation
description: Investigation procedure for Amazon ECS Fargate tasks that stop with
  stopCode EssentialContainerExited, exit code 137, or a stoppedReason containing
  OutOfMemoryError. Use this skill when an ECS service is in a restart loop, when
  task memory utilization climbs steadily before a task dies, or when
  investigating suspected memory leaks in containerized services.
---

# ECS Fargate out-of-memory investigation

Use this when an ECS task has stopped and memory exhaustion is a plausible cause.

The goal is to separate three cases that look identical at the alarm:

1. **Retention (leak)** — memory climbs steadily and never recovers, independent of load.
2. **Under-provisioning** — memory is stable but sits too close to the limit for normal peaks.
3. **Load-driven spike** — memory tracks a traffic or queue-depth increase.

They have different fixes. Do not recommend raising the memory limit until you
have ruled out case 1, because raising the limit on a leak only changes how long
it takes to crash.

## Step 1: Confirm it was actually an OOM kill

Check the stopped task:

- `stopCode` of `EssentialContainerExited` with container `exitCode` 137 means the
  container was killed by the kernel OOM killer.
- `stoppedReason` containing `OutOfMemoryError: Container killed due to memory usage`
  is conclusive.
- A container hard `memory` limit lower than the task-level `memory` means the
  container is killed before the task. Read both from the task definition.

If neither is present, the task died for another reason. Stop and re-triage.

## Step 2: Establish the memory shape, not just the peak

Retrieve memory over a window that covers at least two task lifetimes, not just
the minutes before the kill. A single sawtooth tells you nothing; several
identical sawteeth are the signature of a leak.

- `AWS/ECS` `MemoryUtilization` for the cluster and service, average and maximum.
- With Container Insights: `ECS/ContainerInsights` `MemoryUtilized` per task.

Ask specifically: does memory return to baseline after each restart and then climb
at the same rate again? That pattern is retention, and the slope gives you the
rate.

## Step 3: Correlate against what changed

This is the highest-yield step. Establish the time the behaviour started, then
look for a change that precedes it:

- `RegisterTaskDefinition` and `UpdateService` in CloudTrail for this service.
- Diff the active task definition revision against the previous one. Pay close
  attention to environment variables, image tag, and both memory settings.
- If a code repository is connected, list commits merged shortly before the first
  occurrence.

State explicitly whether the crash loop began before or after the most recent
deployment. If it began after, name the specific revision and the specific
changed field.

## Step 4: If it is retention, find the collection that never shrinks

Retention almost always means something accumulates per unit of work and is
never released. Work outward from the code and config in the task definition:

- **Caches keyed on a unique value.** A cache keyed on something unique per
  request — an order id, a request id, a session id, a timestamp — has unbounded
  key cardinality. It never hits and never stops growing. The same cache keyed on
  a low-cardinality attribute (product, tenant, region) is bounded by that
  attribute's domain. A configuration change that only alters *what the key is*
  looks harmless in a diff and is a common cause.
- **Confirm with the hit rate, not the size alone.** A hit rate at or near zero
  alongside an entry count that tracks total requests is conclusive: every lookup
  is inserting a new entry. A healthy bounded cache shows a high hit rate and an
  entry count that plateaus.
- **Other usual suspects.** Unbounded queues or buffers, accumulating metrics or
  audit lists, listeners or connections registered but never removed, retry
  structures that append on every attempt.

Compare the entry count against the configured bound where one exists. If the
count settles at roughly the size of some catalog, tenant list, or enum, the
cache is behaving. If it climbs with traffic, it is not.

## Step 5: Read the logs for a leading indicator

Search the service log group in the window between task start and task stop.
Look for the last lines before termination — an OOM-killed process is cut off
mid-stream and writes no shutdown message, which is itself a signal.

Useful patterns: growing cache or buffer counts, rising heap or RSS figures,
"memory" warnings, and any metric the application logs about its own retained
state.

## Step 6: Report

Give the answer in this order:

1. **Verdict** — retention, under-provisioning, or load-driven, and your confidence.
2. **Evidence** — the specific metric shape, the specific log lines, the specific
   task definition diff. Quote values, not adjectives.
3. **Which side is wrong.** If two things disagree (for example an environment
   variable and a limit), say which one is the defect and why. Do not simply
   report that they differ.
4. **Mitigation now** — how to restore service.
5. **Fix** — what stops it recurring.

If the evidence does not distinguish between the three cases, say so and name the
one additional piece of data that would settle it.
