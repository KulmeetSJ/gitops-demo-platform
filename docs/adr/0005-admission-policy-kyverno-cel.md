# ADR 0005: Admission policies with Kyverno ValidatingPolicy (CEL), tested in CI

**Status:** accepted · 2026-11-19

## Context
CI scanning (Trivy) only covers images built by our pipeline. Anything else that reaches the API server
(a hand-applied manifest, another team's chart, a compromised pipeline) bypasses it. Admission control is the
last checkpoint before a workload runs. This is defence in depth, not a replacement.

## Decision
- Kyverno 1.20 with **`ValidatingPolicy` (`policies.kyverno.io/v1`, CEL)**. The older `ClusterPolicy` API is deprecated
  in 1.20, and CEL is the same language as Kubernetes' native ValidatingAdmissionPolicy.
- Four policies in **Enforce (Deny)** mode for `dev`, `staging`, `prod`:
  1. no `:latest` / untagged images
  2. CPU and memory requests and limits required
  3. no privileged containers, no `hostPath`
  4. `runAsNonRoot` required
- `autogen` for Deployments, StatefulSets etc., so a bad manifest fails at apply time with a clear message rather than
  later as a silently missing Pod.
- **Policies are tested like code:** `policy-tests/` holds one good and seven bad manifests with expected results
  (`kyverno test`), plus a CI check that the app chart passes every policy in every environment.

## Consequences
- Platform namespaces (`argocd`, `kyverno`, `monitoring`, …) are out of scope. Upstream charts don't all comply,
  and fixing that is a separate hardening task.
- Rollout pods are validated at Pod admission (Rollout isn't an autogen kind), so a non-compliant Rollout shows up
  as a stuck ReplicaSet rather than an apply-time error.
- Next step (stretch): `ImageValidatingPolicy` to admit only cosign-signed images from GHCR.
