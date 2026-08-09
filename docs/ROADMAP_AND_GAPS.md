# Roadmap and Honest Gaps

This document exists because pretending a system is more complete than it is defeats the purpose of documentation. Everything below was genuinely not built during this phase — stated plainly, with what building it properly would actually require.

## Gap 1: CI (Continuous Integration) Pipeline

**What exists:** Continuous **Deployment** via ArgoCD — git commits to `gitops/` are automatically synced to the cluster. This is real and proven.

**What doesn't exist:** any automated build/test/scan pipeline upstream of that. There is no CI system (GitHub Actions, GitLab CI, etc.) running linting, unit tests, container image builds, SAST/dependency scanning, or image vulnerability scanning before a change reaches `gitops/`.

**What a real implementation would add, staged against actual risk (not the full 10-stage template applied blindly — see the source engineering brief this project follows):**
1. Source control trigger + branch protection on `main`
2. Static analysis / linting on any application code (not yet applicable — `hello` is a stock nginx image, no custom code exists yet to lint)
3. Container image build + semantic-version/commit-SHA tagging, if a custom application image is introduced
4. Image vulnerability scanning (e.g., Trivy) — block on critical CVEs
5. Push to a private registry (ECR) with immutable tags
6. Automated rollback triggered by SLO violation, not just available as a manual `kubectl rollout undo`

**Why not built now:** the current workload (`hello`, stock nginx) has no custom code or container image to build/scan — a CI pipeline with nothing of substance to build/test would be pipeline theater. This becomes real and necessary the moment a custom application image is introduced.

## Gap 2: Observability / Monitoring Dashboards

**What exists:** `metrics-server`, providing resource metrics *only* to the Horizontal Pod Autoscaler — this is not a monitoring solution, it explicitly should not be used as one (per the project itself's own documentation).

**What doesn't exist:** metrics collection/storage beyond HPA's immediate needs, dashboards, alerting, distributed tracing, or centralized log aggregation.

**What a real implementation would add:**
- **Metrics:** Prometheus (or Amazon Managed Prometheus) scraping cluster and application metrics, retained beyond the 15-second window `metrics-server` operates on.
- **Dashboards:** Grafana, with at minimum the four golden signals (latency, traffic, errors, saturation) per service, plus cluster-level node/pod health.
- **Logging:** Fluent Bit or the CloudWatch Container Insights integration, aggregating pod logs centrally — currently, `kubectl logs` against a specific pod is the only way to see application output, which doesn't survive pod deletion.
- **Tracing:** not applicable yet — no multi-service call chain exists in this workload to trace.
- **Alerting:** none configured. No SLOs, no error budgets, no on-call paging path exist yet — this is the most significant operational gap for anything beyond a demonstration.

**Why not built now:** genuinely out of scope for the phase this documentation covers, and — same honesty standard as Gap 1 — a dashboard with nothing meaningful flowing into it (single stock nginx app, no real traffic pattern) would demonstrate the *mechanics* of installing Grafana, not real monitoring capability. This is the clear, correctly-sequenced next phase once real workloads exist.

## Gap 3: Secrets Management Beyond Kubernetes-Native Secrets

Kubernetes `Secret` objects are base64-encoded, not encrypted, by default. EKS supports envelope encryption via KMS for `Secret` objects at rest — not yet enabled on this cluster. A production system handling genuinely sensitive application secrets (not just the platform's own internal CA key) should integrate AWS Secrets Manager or HashiCorp Vault via the External Secrets Operator pattern, rather than relying on Kubernetes-native secrets alone.

## Gap 4: Image Admission Control

No policy engine (e.g., Kyverno, OPA Gatekeeper) enforces constraints like "only images from an approved registry" or "no `:latest` tags in production." This platform currently trusts whatever image tag a manifest specifies.

## Gap 5: Chaos / Failure-Injection Testing Beyond Manual Node Termination

The node-failure demonstration (manually terminating an EC2 instance) proves basic self-healing. A mature chaos engineering practice (e.g., AWS Fault Injection Simulator, Chaos Mesh) would test a broader range of failure modes systematically and repeatably — AZ-level network partition, dependency latency injection, control-plane API throttling — rather than one manually-triggered scenario.

## Gap 6: Pod Anti-Affinity / Topology Spread

Deployments currently rely on Kubernetes' default scheduler behavior, not explicit `topologySpreadConstraints` or pod anti-affinity rules. Nothing currently *guarantees* the `hello` app's 2+ replicas land on different nodes or different AZs — under the current small scale this has happened to work out via Karpenter's node selection, but it is not an enforced guarantee. This is a real, fixable gap that would matter more as replica count and criticality increase.

---

**None of the above gaps block the requirements this specific project phase committed to** (see README.md §3). They are documented here precisely so the next phase has an honest starting point instead of rediscovering these limitations under pressure.

