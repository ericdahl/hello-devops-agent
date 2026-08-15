> Verbatim output of a real investigation, flattened from the operator app's
> journal records to markdown. Only the AWS account id and source IP are
> redacted. Nothing else is edited, reordered, or summarised.
>
> The agent received one ECS task-stop event. Everything else here — the
> CloudTrail attribution, the log analysis, the rev 3/rev 4 diff, the growth
> arithmetic — it gathered on its own.
>
> For the earlier, deliberately obvious variant of this demo (which set
> `LEAK_MB_PER_MIN=120` and was solved instantly), see
> [docs/investigation-report-obvious-variant.md](docs/investigation-report-obvious-variant.md).

## order-processor OOM crash loop — unbounded cache growth

`complete`

`Severity: high`

### Incident

The `order-processor` ECS Fargate service in cluster `hello-devops-agent` entered a persistent **~5-minute crash loop** after a task definition update at 17:18:23 UTC. Four consecutive tasks were OOM-killed (exit code 137):

| # | Task ID | Started | OOM-killed |
|---|---------|---------|------------|
| 1 | `adb13b13…` | 17:18:59 | 17:24:03 |
| 2 | `184ee32f…` | 17:24:25 | 17:29:29 |
| 3 | `4b74e20a…` | 17:30:03 | 17:35:09 |
| 4 | `a7d73814…` | 17:35:27 | 17:40:31 |

The service is **non-functional** and will continue this cycle until rolled back.

### Cause

Task definition revision 4 (deployed at 17:18:23 UTC by user `ecd` via manual Terraform apply on macOS) changed `CACHE_KEY_MODE` from `sku` to `order`. This transformed the pricing quote cache from a bounded structure (120 SKU entries, ~2.4 MB) into an unbounded memory leak — every unique order ID creates a ~20 KB entry that is never reused (0% hit rate). At 55 orders/sec, memory grows at ~1.1 MB/s, exhausting the 400 MB container limit in ~5 minutes.

### Mitigation

Roll back the ECS service from task definition revision 4 to revision 3, restoring `CACHE_KEY_MODE=sku` and bounded caching. The service will stabilize immediately upon rollback.

## Mitigation plan

`proposed`

Roll back the ECS service order-processor from task definition revision 4 to revision 3, restoring CACHE_KEY_MODE=sku to eliminate the unbounded memory leak.

Task definition revision 4 changed CACHE_KEY_MODE from 'sku' to 'order', causing the pricing cache to grow without bound at ~1.1 MB/s. **Crash loop confirmed** — 4 consecutive tasks OOM-killed at ~5-minute intervals. The service is completely non-functional. Rolling back to revision 3 restores bounded SKU-based caching (120 entries, ~2.4 MB). Immediate action required.

`prepare`

1. Capture current service state

*Record the current configuration (revision 4, desired count 1) as a baseline before making changes*

```bash
aws ecs describe-services --cluster hello-devops-agent --services order-processor --region us-east-1
```

**Advisory:**
- Save the output — you will need the current task definition ARN if reverting the rollback

`pre validate`

2. Verify target revision exists and is correct

*Confirm revision 3 exists and contains CACHE_KEY_MODE=sku*

```bash
aws ecs describe-task-definition --task-definition hello-devops-agent-order-processor:3 --region us-east-1
```

**Advisory:**
- Verify the environment variable CACHE_KEY_MODE is set to 'sku' in the output

`apply`

3. Roll back to revision 3

*Roll back the service to the known-good revision with bounded caching*

```bash
aws ecs update-service --cluster hello-devops-agent --service order-processor --task-definition hello-devops-agent-order-processor:3 --force-new-deployment --region us-east-1
```

**Risks:**
- Brief service interruption during task replacement (~30s)

`post validate`

4. Confirm service stability

*Verify running count = desired count (1), task definition points to revision 3, and no further OOM restarts*

```bash
aws ecs describe-services --cluster hello-devops-agent --services order-processor --region us-east-1
```

**Advisory:**
- Monitor for 5-10 minutes to confirm the task remains stable — the previous config would crash within ~5 minutes

`rollback`

5. Revert if revision 3 has unexpected issues

*Restore revision 4 only if revision 3 has a previously unknown problem worse than the OOM loop*

```bash
aws ecs update-service --cluster hello-devops-agent --service order-processor --task-definition hello-devops-agent-order-processor:4 --force-new-deployment --region us-east-1
```

**Risks:**
- Restoring revision 4 will re-introduce the OOM crash loop

### Code change specification

**1. Restore bounded pricing cache**

Revert CACHE_KEY_MODE environment variable from 'order' back to 'sku' in the task definition to restore bounded cache behavior

Acceptance criteria:
- CACHE_KEY_MODE=sku in the active task definition
- Cache entries stable at ≤120 after warm-up
- Cache hit rate approaches 100% in steady state
- No OOM kills for 10+ minutes of operation

Container memory limit

## 400 MB

Cache growth rate

## ~1.1 MB/s

`critical`

Cache hit rate

## 0 %

`critical`

Time to OOM

## ~5 min

`critical`

Consecutive OOM kills

## 4

`critical`

## Cache growth & crash loop

## Findings & evidence

`root cause`

Task definition rev 4 deployed via manual Terraform apply changed CACHE_KEY_MODE to 'order'

User `ecd` ran `terraform apply` from a macOS ARM64 laptop at 2026-08-15T17:18:23Z via AWS SSO AdministratorAccess role. This updated the ECS service from task definition revision 3 (CACHE_KEY_MODE=sku, v1.4.2) to revision 4 (CACHE_KEY_MODE=order, v1.5.0). The change transformed the pricing quote cache from a bounded data structure (120 SKU entries) into an unbounded memory leak (unique order ID per entry, never reused).

**CloudTrail evidence:**
- Event: UpdateService at 17:18:23Z
- Principal: arn:aws:sts::<account-id>:assumed-role/AWSReservedSSO_AdministratorAccess_c5fea06c9e38cec8/ecd
- User Agent: Terraform/1.5.7 on macOS ARM64
- Source IP: <redacted>

`cause`

Unbounded cache growth from CACHE_KEY_MODE=order causes OOM

With CACHE_KEY_MODE=order, the pricing quote cache keys on unique order IDs instead of the bounded set of 120 SKUs. Since every order ID is unique, no cache entry is ever reused (0% hit rate), and the cache grows linearly at ~825 entries per 15 seconds (~55 orders/s). Each entry is ~20 KB, producing ~1.1 MB/s of memory growth. The 400 MB container limit is exhausted in ~5 minutes.

**Comparison:**
| Mode | Cache key | Entries | Hit rate | Memory | Outcome |
|------|-----------|---------|----------|--------|---------|
| sku (rev 3) | SKU ID | Bounded at 120 | 100% | ~2.4 MB stable | Healthy |
| order (rev 4) | Order ID | Unbounded (14,872+ observed) | 0% | ~1.1 MB/s growth | OOM in ~5 min |

`symptom`

order-processor OOM crash loop — 4 consecutive kills — 2026-08-15T17:24:03Z → 2026-08-15T17:40:31Z

The order-processor container is being OOM-killed (exit code 137) every ~5 minutes in a persistent crash loop. Each task runs for approximately 5 minutes before exceeding its 400 MB memory limit.

| # | Task ID | Started | OOM-killed | Runtime |
|---|---------|---------|------------|--------|
| 1 | adb13b13… | 17:18:59 | 17:24:03 | ~5 min |
| 2 | 184ee32f… | 17:24:25 | 17:29:29 | ~5 min |
| 3 | 4b74e20a… | 17:30:03 | 17:35:09 | ~5 min |
| 4 | a7d73814… | 17:35:27 | 17:40:31 | ~5 min |

2026-08-15T17:24:03Z → 2026-08-15T17:40:31Z

`observation`

Task definition rev 3 → rev 4 configuration diff

The only meaningful change between revisions is the CACHE_KEY_MODE environment variable:

- Rev 3: APP_VERSION=1.4.2, CACHE_KEY_MODE=sku
- Rev 4: APP_VERSION=1.5.0, CACHE_KEY_MODE=order

All other settings (image, CPU, memory, TARGET_ORDER_RATE=55, CATALOG_SIZE=120) are identical. The application code is embedded in the task definition command and is unchanged between revisions — the behavioral difference is entirely driven by the environment variable.

`observation`

Application logs confirm linear unbounded cache growth with 0% hit rate

CloudWatch Logs from the OOM-killed task show cache_entries growing linearly from 836 to 14,872+ over ~4.5 minutes with cache_hit_rate=0.00 throughout. The baseline (healthy) task shows cache_entries stable at 120 with hit_rate=1.00 after warm-up.

**OOM-killed task (rev 4):** 836 → 14,872 entries, 0% hit rate, +825 entries/15s
**Healthy task (rev 3):** Stable at 120 entries, 100% hit rate after warm-up

The last log was at 17:23:30 (cache_entries=14,872). The container was SIGKILL'd at 17:24:03 — a ~30s gap where the process was likely memory-starved and unable to write logs.
