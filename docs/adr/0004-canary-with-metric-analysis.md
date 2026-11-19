# ADR 0004: Argo Rollouts canary, judged by the canary pods' own Prometheus metrics

**Status:** accepted · 2026-11-19

## Context
A rolling update stops on failed health probes, but a version can be *Ready* and still be bad (errors or latency
on real requests). `FAULT_RATE` reproduces exactly that: health endpoints stay green while `/api` returns 500s.

## Decision
- **Canary over blue-green:** blue-green needs double capacity at cutover, and the laptop cluster can't spare it.
  The canary also exposes a bad build to a fraction of traffic first. Argo Rollouts was chosen over Flagger because
  it fits Argo CD natively (health checks, UI, same project).
- **Steps:** 10% → 25% → 50% → 100% with 60 s pauses. Weights are replica-based (no traffic router, ADR 0002).
- **Background analysis** from the first canary step, two metrics:
  - success rate (non-5xx / all, excluding `/actuator`) ≥ 99%
  - p95 latency ≤ 500 ms
- **Canary-only queries:** the ServiceMonitor copies `rollouts-pod-template-hash` onto every series, and the
  AnalysisTemplate selects on the canary's hash. Without this the stable pods dilute the canary's errors.
- **Failure handling:** `failureLimit: 1` (abort on the 2nd failed measurement, which tolerates one blip).
  No-traffic (NaN) matches neither condition, so it is *Inconclusive* and pauses for a human; it never passes silently.
- **Traffic:** an in-cluster curl load generator (~8 req/s) per env, so analysis always has data.

## Consequences
- Switching `Deployment` → `Rollout` under Argo CD replaces the workload once (brief disruption on that first sync).
  In a real migration, `workloadRef` adopts the existing Deployment with zero downtime.
- Analysis needs enough requests per interval to be meaningful. At 8 req/s and a 1-minute rate window, a 20% fault rate
  on the canary is unambiguous, but a 0.5% regression would not be detectable. That's a statistical-power limit
  worth stating in interviews.
