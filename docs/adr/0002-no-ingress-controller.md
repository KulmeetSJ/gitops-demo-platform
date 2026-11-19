# ADR 0002: No ingress controller (ingress-nginx is retired)

**Status:** accepted · 2026-11-19

## Context
The original plan included ingress-nginx. The project was retired and its repository archived in March 2026, so it
gets no further security fixes.

## Decision
- Don't install an ingress controller. UIs and the app are reached with `kubectl port-forward`.
- Phase 3 canaries use Argo Rollouts' **replica-weighted** traffic split (no traffic router needed), so nothing
  depends on an ingress.

## Consequences
- Canary weights are approximate (they follow replica ratios). If precise weights are needed later, add a
  Gateway API implementation (for example Envoy Gateway) and Argo Rollouts' Gateway API plugin.
