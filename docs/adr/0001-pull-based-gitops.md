# ADR 0001: Pull-based GitOps; CI never holds cluster credentials

**Status:** accepted · 2026-11-19

## Context
A push-based pipeline (`kubectl apply`/`helm upgrade` from CI) needs cluster-admin-like credentials stored in CI, and
the cluster's state drifts from what anyone can review.

## Decision
- CI's only output is an image in GHCR and a **commit** to this repo. Argo CD, running inside the cluster, pulls.
- Every environment is a directory under `envs/`; an `ApplicationSet` turns each directory into an Application.
- Promotion copies an immutable image SHA from one env file to the next. Prod promotion runs in a job bound to
  the GitHub `production` environment, so it needs a required reviewer's approval.
- `selfHeal: true`: manual changes in the cluster are reverted to what Git says.

## Consequences
- The approval sits on the **change to Git**, not on cluster access. The audit trail is commit history plus
  GitHub deployment records.
- GitHub-hosted runners can't reach a laptop cluster, and with pull-based delivery they don't need to.
- Deploy latency includes Argo CD's poll interval (60 s here). In a real setup a Git webhook removes most of it.
- Promotion commits go straight to `main` from the workflow rather than via auto-merged PRs. This avoids granting
  Actions permission to create and approve PRs, at the cost of no PR-level review on promotions.
