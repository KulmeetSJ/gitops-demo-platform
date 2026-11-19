# gitops-demo-platform

[![ci](https://github.com/KulmeetSJ/gitops-demo-platform/actions/workflows/ci.yml/badge.svg)](https://github.com/KulmeetSJ/gitops-demo-platform/actions/workflows/ci.yml)

The GitOps side of the delivery platform for [gitops-demo-app](https://github.com/KulmeetSJ/gitops-demo-app):
a local Kubernetes cluster where **Git is the only way anything reaches the cluster**.

```
gitops-demo-app CI ──(green main build)──► commits image tag to envs/dev ─┐
promote.yml  dev → staging ───────────────► commits to envs/staging ──────┤   Argo CD polls this repo
promote.yml  staging → prod (needs approval) ► commits to envs/prod ──────┘   and syncs each env
                                                                              (CI never holds cluster credentials)
kind cluster: Argo CD · Argo Rollouts · kube-prometheus-stack · Kyverno · Sealed Secrets
namespaces:   dev · staging · prod  (app + its own PostgreSQL in each)
```

## Quick start
Requires Docker (~8 GB of memory for Docker Desktop), `kind`, `kubectl`, `helm`, `kubeseal`.
```bash
make up        # kind cluster + Argo CD; Argo CD installs everything else from argocd/apps/
make status    # applications and pods per environment
make down      # delete the cluster (the Sealed Secrets key backup is kept)
```

## Layout
| Path | What it is |
|---|---|
| `bootstrap/` | kind config, Argo CD values, `up.sh` (the only imperative step) |
| `argocd/root.yaml` | App of apps → `argocd/apps/` |
| `argocd/apps/` | Platform components (pinned chart versions) + the app's `ApplicationSet` |
| `charts/gitops-demo-app/` | Helm chart: app `Deployment`, per-env PostgreSQL, `ServiceMonitor` |
| `envs/<env>/values.yaml` | The image tag and sizing per environment. **Promotion = changing this file.** |
| `envs/<env>/secrets/` | `SealedSecret`s (encrypted; safe to commit) |
| `.github/workflows/promote.yml` | dev → staging, staging → prod (gated by the `production` environment) |

## Promotion flow
1. A green build on `main` in the app repo pushes `ghcr.io/kulmeetsj/gitops-demo-app:<sha>` and commits that SHA to `envs/dev`.
2. **Actions → promote → target: staging** copies dev's tag to staging.
3. **Actions → promote → target: prod** waits for a required reviewer on the `production` environment, then copies staging's tag to prod.

There is no `kubectl apply` in any pipeline. Argo CD reconciles each environment from Git within about 60 s.

## Design decisions
See [`docs/adr/`](docs/adr/).
