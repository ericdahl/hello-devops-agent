> **Baseline from the earlier, deliberately obvious variant.**
>
> This run is kept for comparison. At the time, the task definition carried
> `LEAK_MB_PER_MIN=120`, which named the fault outright — the agent read the
> variable and was done. The current demo replaces that with a cache whose key
> cardinality changes, and nothing in the container names the fault. Expect a
> materially different investigation.

# Investigation Summary

## Symptoms

### Order Processor ECS task OOM crash loop
**Description:** ECS task `f26e71f225794f47b68977b3e1990ae0` on cluster `hello-devops-agent` is killed with exit code 137 (OutOfMemoryError) approximately 3.3 minutes after each start, then immediately restarts into the same crash loop. First OOM at 2026-08-14T17:45:30Z.
**Time:** 2026-08-14T17:45:30Z

## Findings

### Root Cause: LEAK_MB_PER_MIN changed from 0 to 120 in task definition revision :2
**Description:** Task definition `hello-devops-agent-order-processor:2` (registered 2026-08-14T17:41:15Z) changed the environment variable `LEAK_MB_PER_MIN` from `0` to `120` and bumped `APP_VERSION` from `1.4.2` to `1.5.0`. The application code intentionally retains memory at the configured rate — 120 MB/min (~10 MB every 5 seconds). With a 400 MB container hard limit, OOM kill is guaranteed within ~3.3 minutes of every cold start. The previous revision :1 had `LEAK_MB_PER_MIN=0` and ran in steady state with no memory growth.
**Cascades to:** symptom-oom-crash-loop

---

# Mitigation Summary

## Action
Roll back ECS service 'order-processor' to task definition revision :1 (LEAK_MB_PER_MIN=0)

## Reasoning
Task definition revision :2 introduced LEAK_MB_PER_MIN=120, causing deterministic OOM kills every ~3.3 minutes. Revision :1 has LEAK_MB_PER_MIN=0 (healthy steady state). Rolling back immediately stops the crash loop. The change was a manual Terraform apply — no pipeline to revert through.

## Execution Plan

### Step 1: Prepare

#### 1.1 aws ecs describe-services --cluster hello-devop...
**Type:** command
```
aws ecs describe-services --cluster hello-devops-agent --services order-processor --region us-east-1
```
**Purpose:** Back up current config (revision :2) for potential re-application

### Step 2: Pre Validate

#### 2.1 aws ecs describe-task-definition --task-definit...
**Type:** command
```
aws ecs describe-task-definition --task-definition hello-devops-agent-order-processor:1 --region us-east-1
```
**Purpose:** Verify revision :1 exists and contains LEAK_MB_PER_MIN=0
**Advisory:** If revision :1 is deleted, register a new task definition with LEAK_MB_PER_MIN=0 instead

### Step 3: Apply

#### 3.1 aws ecs update-service --cluster hello-devops-a...
**Type:** command
```
aws ecs update-service --cluster hello-devops-agent --service order-processor --task-definition hello-devops-agent-order-processor:1 --force-new-deployment --region us-east-1
```
**Purpose:** Switch to healthy task definition and force immediate replacement of the crashing task
**Advisory:** Brief unavailability during rolling deployment (desiredCount=1)

### Step 4: Post Validate

#### 4.1 aws ecs describe-services --cluster hello-devop...
**Type:** command
```
aws ecs describe-services --cluster hello-devops-agent --services order-processor --region us-east-1
```
**Purpose:** Confirm deployment completed, runningCount=1, task definition is revision :1
**Advisory:** Allow 2-3 minutes for deployment to stabilize before checking

### Step 5: Rollback

#### 5.1 aws ecs update-service --cluster hello-devops-a...
**Type:** command
```
aws ecs update-service --cluster hello-devops-agent --service order-processor --task-definition hello-devops-agent-order-processor:2 --force-new-deployment --region us-east-1
```
**Purpose:** Restore revision :2 only if revision :1 has unrelated critical problems
**Risks:** Re-introduces LEAK_MB_PER_MIN=120 and the OOM crash loop

---

# Investigation Summary

## Symptoms

### ECS task OOM crash loop
**Description:** ECS tasks in service order-processor on cluster hello-devops-agent are repeatedly OOM-killed (exit code 137) after ~3.3 minutes of runtime. The container memory grows linearly at 120 MB/min until hitting the 400 MB hard limit. CloudWatch memory alarm triggered at 69% utilization (17:52:00Z) on the latest restarted task, confirming the crash loop is ongoing.
**Time:** 2026-08-14T17:45:30Z

## Findings

### Root Cause: LEAK_MB_PER_MIN changed from 0 to 120 in task definition revision :2
**Description:** Task definition hello-devops-agent-order-processor:2, registered at 17:41:15Z, changed the environment variable LEAK_MB_PER_MIN from 0 (healthy) to 120, causing the application to retain 120 MB of memory per minute via an unbounded cache. With a 400 MB container hard limit, this guarantees OOM kill in ~3.3 minutes. The change was deployed by user &lt;redacted&gt; via manual Terraform apply (Terraform 1.5.7, macOS/arm64, IP &lt;redacted&gt;). ECS deployment circuit breaker is disabled, preventing automatic rollback.
**Cascades to:** symptom-oom-crash-loop

---

# Mitigation Summary

## Action
Roll back ECS service to task definition revision :1 (LEAK_MB_PER_MIN=0)

## Reasoning
Task definition revision :2 introduced LEAK_MB_PER_MIN=120, causing the container to retain 120 MB/min against a 400 MB hard limit. Rolling back to revision :1 (LEAK_MB_PER_MIN=0) immediately stops the OOM crash loop. Expected recovery: 2-3 minutes.

## Execution Plan

### Step 1: Prepare

#### 1.1 aws ecs describe-services --cluster hello-devop...
**Type:** command
```
aws ecs describe-services --cluster hello-devops-agent --services order-processor --region us-east-1
```
**Purpose:** Backup current config (revision :2) for potential re-deployment

### Step 2: Pre Validate

#### 2.1 aws ecs describe-task-definition --task-definit...
**Type:** command
```
aws ecs describe-task-definition --task-definition hello-devops-agent-order-processor:1 --region us-east-1
```
**Purpose:** Verify revision :1 exists and has LEAK_MB_PER_MIN=0

### Step 3: Apply

#### 3.1 aws ecs update-service --cluster hello-devops-a...
**Type:** command
```
aws ecs update-service --cluster hello-devops-agent --service order-processor --task-definition hello-devops-agent-order-processor:1 --force-new-deployment --region us-east-1
```
**Purpose:** Restore healthy task definition with no memory leak
**Risks:** Brief period of unavailability during rolling deployment (desiredCount=1)

### Step 4: Post Validate

#### 4.1 aws ecs describe-services --cluster hello-devop...
**Type:** command
```
aws ecs describe-services --cluster hello-devops-agent --services order-processor --region us-east-1
```
**Purpose:** Confirm rolloutState=COMPLETED, runningCount=1, task definition=revision :1
**Advisory:** Allow 2-3 minutes for the deployment to complete before checking

### Step 5: Rollback

#### 5.1 aws ecs update-service --cluster hello-devops-a...
**Type:** command
```
aws ecs update-service --cluster hello-devops-agent --service order-processor --task-definition hello-devops-agent-order-processor:2 --force-new-deployment --region us-east-1
```
**Purpose:** Only if revision :1 causes unexpected issues unrelated to the memory leak
**Risks:** Re-introduces LEAK_MB_PER_MIN=120 and the OOM crash loop

---

