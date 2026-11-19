# ADR 0003: Sealed Secrets, with the controller key backed up outside Git

**Status:** accepted · 2026-11-19

## Context
The DB password per environment has to live in Git (GitOps) without being readable. A local kind cluster is often
deleted and recreated, and a new Sealed Secrets controller generates a new key that can't decrypt existing
`SealedSecret`s.

## Decision
- Use Bitnami Sealed Secrets with **strict** scope: each secret is bound to its name and namespace.
- `scripts/seal-db-secret.sh` generates a random password and pipes it straight into `kubeseal`; the plaintext
  never touches disk.
- `bootstrap/up.sh` backs up the controller key to `~/.config/gitops-demo/` (mode 600, never committed) on the first
  run, and restores it before the controller starts on later runs.

## Alternatives
External Secrets Operator + GCP Secret Manager is the better choice on GKE (no key to manage, central rotation),
but it needs a cloud account. Sealed Secrets keeps the project free and self-contained.

## Consequences
- Whoever holds the key backup can decrypt every secret in the repo, so it is handled like a root credential.
- Rotation means re-sealing and committing.
