# Results

All numbers are **personal-project benchmarks** on a local kind cluster, not production results.
Environment: Apple M2, 16 GB RAM (8 GB for Docker Desktop), kind v0.33 / Kubernetes v1.36.4, GitHub-hosted runners.

## First end-to-end promotion (2026-11-19)
App commit [`27be0f5`](https://github.com/KulmeetSJ/gitops-demo-app/commit/27be0f527edb0391af16608bbd4186ba465a81d1), promoted dev → staging → prod with no `kubectl apply` by hand.

| Stage | Evidence | Time |
|---|---|---|
| Push → new pod Ready in **dev** (CI + GitOps commit + Argo CD poll + rollout) | CI [run](https://github.com/KulmeetSJ/gitops-demo-app/actions/runs/44445721617) → platform commit `c786707` | **4m41s** (CI 2m41s) |
| `promote → staging` | [run](https://github.com/KulmeetSJ/gitops-demo-platform/actions/runs/44446319268) → `6e5f3b7` | staging live < 1 min after the commit |
| `promote → prod`: waited for a required reviewer on `production` | [run](https://github.com/KulmeetSJ/gitops-demo-platform/actions/runs/44446403322) approved by KulmeetSJ → `75c127c` | prod (2 replicas) live **78 s** after the promotion commit; the approval wait is excluded and reported separately |

- Single observation. Phase 4 scripts this (`scripts/measure_lead_time.sh`) and reports a median over several runs.
- Most of the GitOps part of the latency is Argo CD's 60 s poll interval (ADR 0001).

## Drift correction
- I ran `kubectl scale deploy/gitops-demo-app --replicas=3` in `dev` (Git says 1). Argo CD (`selfHeal: true`) reverted it in **about 1 s**.
