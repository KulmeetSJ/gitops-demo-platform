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

- Single observation, before canaries were added. See *Measured medians* below for the scripted 3-run median.
- Most of the GitOps part of the latency is Argo CD's 60 s poll interval (ADR 0001).

## Drift correction
- I ran `kubectl scale deploy/gitops-demo-app --replicas=3` in `dev` (Git says 1). Argo CD (`selfHeal: true`) reverted it in **about 1 s**.

## Automated canary rollback (2026-11-19)
`faultRate: "0.2"` committed to `envs/dev` (`63f65e5`): a release that passes health probes but fails 20% of `/api` requests.

| Time (UTC) | Event |
|---|---|
| 04:05:37 | Bad config committed |
| 04:05:40 | Canary ReplicaSet created (revision 2) |
| 04:06:04 | Step 1 (10%) done; background analysis starts |
| 04:07:04 | Measurement 1: success rate **77.1%** (< 99%) → failed |
| 04:07:34 | Measurement 2: **79.5%** → `failureLimit` exceeded → **rollout aborted, canary scaled 1 → 0** |

- **First failed analysis → canary removed (stable serving 100%): 30 s.** This equals one analysis interval, because `failureLimit: 1` tolerates one blip by design.
- No human action. The stable pod served throughout (`maxUnavailable: 0`). p95 latency stayed at about 12 ms; only the success-rate metric caught it.
- Git was then reverted (`b4c3ca8`) so the desired state matches the stable version. The Rollout went back to Healthy in 5 s with no new canary.
- Measured success rates (77–80%) match the injected 20% fault rate, which shows the analysis reads the canary pods only.

## Healthy canary promoted (2026-11-19)
App commit [`d689d29`](https://github.com/KulmeetSJ/gitops-demo-app/commit/d689d2938101c5e63b9d0ca0cc389da37f615648) (build info endpoint) went through CI → dev canary.
- 10% → 25% → 50% → 100% in **3m30s** (04:53:27 → 04:56:57). Analysis passed 5/5 success-rate checks (100%) and 5/5 p95 checks (about 11 ms).
- Confirms the gate does not block good releases (no false positive).

## Admission policy enforcement (2026-11-19)
Kyverno 1.20 `ValidatingPolicy`, Enforce mode, in `dev`/`staging`/`prod`.

| Manifest (`policy-tests/resources/`) | Live cluster (`kubectl apply --dry-run=server`) | Policy |
|---|---|---|
| good-pod | ✅ admitted | (all pass) |
| bad-latest-tag | ❌ denied | disallow-latest-tag |
| bad-untagged-image | ❌ denied | disallow-latest-tag |
| bad-no-limits | ❌ denied | require-requests-limits |
| bad-privileged | ❌ denied | disallow-privileged-hostpath |
| bad-hostpath | ❌ denied | disallow-privileged-hostpath |
| bad-run-as-root | ❌ denied | require-run-as-non-root |
| bad-deployment-latest (Deployment, autogen) | ❌ denied at apply time | disallow-latest-tag |

- **7/7 non-compliant manifests blocked, 0/1 compliant blocked.** Each denial names the policy and gives a fix-oriented message.
- The same expectations run in CI with `kyverno test` (12/12 assertions), plus a check that the app chart passes every policy in every environment.

## Measured medians (Phase 4, 2026-11-19)
Scripts run the pipeline unattended and read every timestamp from GitHub Actions or the cluster; no stopwatch.
Raw rows: [`measurements/lead_time.csv`](measurements/lead_time.csv), [`measurements/rollback.csv`](measurements/rollback.csv).

### Deploy lead time: `scripts/measure_lead_time.sh <sha> --promote`
Three app commits, each promoted dev → staging → prod. "Healthy" means the Rollout runs that image **and** the canary has finished.
The prod approval is a real human click; its wait is subtracted and shown separately.

| Stage (since push) | Run 1 `35fb875` | Run 2 `282a9d2` | Run 3 `a88078e` | **Median** |
|---|---|---|---|---|
| CI green (test, image, Trivy, SBOM, publish) | 2m48s | 2m14s | 2m40s | **2m40s** |
| dev Healthy | 7m51s | 6m19s | 8m01s | **7m51s** |
| staging Healthy | 13m01s | 11m40s | 12m42s | **12m42s** |
| prod Healthy | 22m02s | 17m12s | 19m49s | **19m49s** |
| Human approval wait | 4m50s | 1m12s | 1m09s | 1m12s |
| **Lead time excluding approval** | 17m12s | 16m00s | 18m40s | **17m12s** |

- Runs 2 and 3 were empty commits, so they measure the pipeline, not a code change.
- Most of the time is the canary steps (about 3.5 min per environment) plus Argo CD's 60 s poll (ADR 0001). The pipeline is deliberately slow for safety, not slow by accident.

### Automated rollback: `scripts/measure_rollback.sh 5 0.2`
Five bad releases (`FAULT_RATE=0.2`: health probes stay green, 20% of `/api` requests fail), each pushed through Git to `dev`.

| Metric | Median | Min | Max |
|---|---|---|---|
| First failed analysis → canary removed | **30 s** | 30 s | 30 s |
| Bad version serving traffic | **90 s** | 89 s | 90 s |
| Push → restored (stable serving 100%) | **184 s** | 141 s | 222 s |

- 5/5 bad releases caught and aborted by metric analysis, with no human action. Measured success rates were 79–86% against the 99% threshold.
- Detection-to-rollback is exactly one analysis interval every time (`failureLimit: 1`). The spread in push → restored is Argo CD's poll timing.

## Incidents noted
- One CI image build failed fetching the Maven distribution inside `docker build` (transient download error; passed on re-run). Fixed in app commit `35fb875`: the build stage now uses an official Maven image pinned by digest, so the build doesn't download Maven.
- Rollback drill 3 was spoiled twice and both rows were discarded. First, the cluster was paused mid-drill. Second, the re-run overlapped a CI deploy to `dev` that replaced the canary. The recorded run 3 is a clean re-run. Lesson: the drill needs exclusive use of `envs/dev`.
