---
name: workload-incident-investigation
description: General procedure for investigating a workload that has become
  unhealthy - a container or task that stopped, a target failing health checks,
  rising latency or error rates, or a process that died unexpectedly. Use this
  when an incident names a compute resource but not a cause.
---

# Investigating an unhealthy workload

You have an event saying something is wrong. It does not tell you why, and its
wording may be misleading — a health check failure and a crash produce different
events for the same underlying defect.

The procedure below is deliberately about method rather than symptoms. Do not
skip to a cause because the event resembles one you have seen before.

## Step 1: Establish what actually happened

Before forming any hypothesis, get the primary evidence for the failure itself:

- If a process or container stopped: its exit status, termination signal, and
  any reason string recorded by the orchestrator. Distinguish "stopped because
  we asked it to" from "stopped because something killed it" — deployments,
  scaling and health-check replacements all produce stop events that are not
  incidents.
- If a health check failed: whether the probe got a response, a wrong response,
  or no response at all. These three have different causes.
- If a metric crossed a threshold: the actual series, not the breach. Thresholds
  tell you when someone drew a line, not when behaviour changed.

State what you established, with the value you read. If the evidence does not
support the event's own framing, say so.

## Step 2: Establish the shape over time

A single data point is not a diagnosis. Retrieve a window long enough to contain
several occurrences and answer:

- Is this continuous, periodic, or a one-off?
- Did it start abruptly or degrade gradually?
- Does the affected resource recover on its own, and if so does the problem
  restart from the same baseline each time?
- Does the shape track load, or is it independent of it?

Repetition with an identical profile means something deterministic. Correlation
with traffic means something load-dependent. Gradual drift with no recovery
means something is accumulating.

## Step 3: Correlate against what changed

This is the highest-yield step in most investigations. Fix the time the
behaviour started, then look for anything that precedes it:

- Deployments, configuration updates, task or pod spec revisions, feature flags.
- Infrastructure changes in the control plane audit log.
- Changes in a dependency rather than the failing component itself.
- Commits merged shortly before the onset, if a repository is connected.

Diff the current revision against the previous one and read every changed field,
including ones that look cosmetic. State plainly whether onset was before or
after the most recent change. "Nothing changed" is a real and important finding
— say it explicitly rather than leaving it implied.

## Step 4: Separate the failure from its trigger

Most incidents have both a latent defect and something that exposed it. A limit
that was always too low, exposed by a traffic increase. A timeout that was always
too aggressive, exposed by a slower dependency. An unhandled case that was always
reachable, exposed by new input.

Name both. Recommending a fix for only the trigger leaves the defect in place;
fixing only the defect may not explain the timing.

Where two pieces of configuration disagree, decide which one is wrong rather
than reporting that they differ.

## Step 5: Corroborate from an independent source

A hypothesis supported by one signal is a guess. Before calling it a cause, find
a second, independent source that agrees — application logs against
infrastructure metrics, an audit log against a resource's current state, a
downstream dependency's view against the failing component's own.

Prefer evidence the application produces about itself over inference from
platform metrics, and quote the specific lines or values.

Note the absence of expected evidence too. A process that is killed abruptly
writes no shutdown message, and that silence is informative.

## Step 6: Report

In this order:

1. **Verdict** — what failed, what caused it, and your confidence.
2. **Evidence** — specific values, specific log lines, specific diffs. Quote
   numbers, not adjectives.
3. **Mitigation** — how to restore service now, with the tradeoffs of doing so.
4. **Fix** — what stops it recurring, which is often not the same action.

If your evidence is consistent with more than one cause, say so and name the one
piece of data that would separate them. A clearly stated uncertainty is more
useful than a confident guess.

Be suspicious of a remediation that only increases a limit, adds capacity, or
restarts something on a schedule. Those are sometimes correct, but they are also
what a wrong diagnosis looks like when the real defect is still there.
