# Capacity Planning and Cost Analysis

## Capacity — Instance Types in Use

Constrained to the AWS account's Free Plan allow-list (accounts created after July 15, 2025 — see INCIDENTS.md #2):

| Instance type | vCPU | Memory | Max pods (ENI-limited) | Role |
|---|---|---|---|---|
| `t3.small` | 2 | 2 GiB | ~11 | System node group (static, 2 nodes) |
| `t4g.small` | 2 | 2 GiB | ~11 | Karpenter-provisioned (Graviton preferred by Karpenter's own cost-aware selection) |
| `t3.micro` / `t4g.micro` | 2 (burstable) | 1 GiB | ~4 | Available to Karpenter, not yet exercised in testing |

**Real bottleneck discovered under load (see ARCHITECTURE.md "Stress Conditions"):** pods-per-node ceiling from ENI IP allocation limits, not CPU/memory. A workload profile with many small pods will exhaust pod slots before exhausting compute — this must be accounted for explicitly in any future capacity model, not assumed away by looking at CPU/memory graphs alone.

## Autoscaling Boundaries

- **Karpenter NodePool limit:** `cpu: 20` — a hard ceiling. Regardless of pending pod demand, Karpenter will never provision beyond 20 total vCPU across all its nodes. This is a deliberate safety rail against runaway scaling from a bug or unbounded workload.
- **HPA:** `minReplicas: 2`, `maxReplicas: 10`, target 50% average CPU utilization on the `hello` Deployment.
- **Consolidation:** `consolidationPolicy: WhenEmptyOrUnderutilized`, `consolidateAfter: 30s` — Karpenter actively reclaims underutilized nodes, not just scales up.

## Cost Analysis

### Unit economics (confirmed rates, `us-east-1`)

| Resource | Rate | Notes |
|---|---|---|
| EKS control plane | $0.10/hr flat | Regardless of cluster size |
| NAT Gateway ×3 | ~$0.045/hr each (~$0.135/hr combined) | Deliberate 3-AZ choice, see ADR-001 |
| Network Load Balancer | ~$0.0225/hr + data processing | One NLB total, shared across all Ingress-routed traffic |
| `t3.small`/`t4g.small` nodes | ~$0.0166-0.0208/hr each | Varies by architecture; Karpenter prefers Graviton (`t4g`) when cost-equivalent |
| EBS gp2 volumes | ~$0.10/GB-month | 1Gi test volume ≈ $0.10/month |
| Route53 private hosted zone | $0.50/month flat + negligible query cost | |

**Approximate steady-state cost while fully running:** ~$0.30-0.35/hour all-in (~$220-250/month if left running continuously).

### Actual spend discipline

This project was never left running continuously — deliberate destroy/rebuild cycles between working sessions were the primary cost control, not architectural minimization. This is itself a real, applicable FinOps pattern: **non-production environments should not run 24/7 by default.** A scheduled teardown (e.g., a nightly CI job running `pre-destroy.sh`, a scheduled `terraform apply` each morning) would formalize this manually-applied discipline — noted as a next-phase automation candidate.

### Actual spend for this build

**Cost Explorer showed near-$0 for the entire session** (`aws ce get-cost-and-usage` returned amounts on the order of $0.0000000001). This does not mean the architecture ran free — it means the AWS account's Free Plan included credits (see ADR context, Incidents #2) absorbed the real usage before it appeared as a billed amount. Presenting that raw $0 without this context would be misleading.

**Reference cost calculation** (list-price based, not Cost Explorer's credit-masked output):

| Component | Rate | 
|---|---|
| EKS control plane | $0.10/hr |
| 3× NAT Gateway | $0.135/hr combined |
| NLB | ~$0.0225/hr |
| 2-4× nodes | ~$0.03-0.07/hr |
| EBS + Route53 | <$0.01/hr combined |
| **Total** | **~$0.30-0.35/hr** |

**Estimated total runtime across this session:** approximately 6 distinct build/destroy cycles (initial build, a rebuild after a lost development-environment session, and several rebuild cycles during the Karpenter/multi-environment/HPA work), each with infrastructure live for an estimated 2-4 hours — roughly **15-20 hours of total billable runtime**, based on session timestamps rather than exact per-cycle stop/start logging.

**Reference total: 15-20 hours × ~$0.325/hr ≈ $4.90-$6.50**, had this session run outside the Free Plan credit window. Stated explicitly as a methodology-based estimate, not a reconstructed exact bill — the real, precise number is what Cost Explorer will show once the account exits its credit period, and should be re-pulled at that time for an exact figure.

**The actual cost lesson this session demonstrates:** the repeated destroy/rebuild discipline — never leaving infrastructure running idle between work sessions — is what kept this number this low regardless of credits. That habit is the real, portable cost-control practice here, more than any single architecture choice.

## Cost Optimization Opportunities (Not Yet Applied)

- **Savings Plans / Reserved capacity** — not applicable to this workload pattern (destroy/rebuild cycles, not steady-state); would only make sense if this ran continuously.
- **Spot capacity for Karpenter nodes** — NodePool currently specifies `capacity-type: on-demand` implicitly (not set to `spot`). Spot would meaningfully reduce node cost for fault-tolerant, non-critical workloads like `dev`/`staging`, at the cost of possible interruption — a reasonable next optimization, deliberately not applied yet to avoid adding interruption-handling complexity during initial build-out.
- **Reverting to 1 shared NAT Gateway** — explicitly rejected for now, see ADR-001. Real trade-off, not a missed optimization.

