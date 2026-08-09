# Architecture Decision Records

Format: Context → Decision → Alternatives Rejected → Trade-offs → What Would Revisit This.

---

## ADR-001: Three NAT Gateways (one per AZ), not one shared

**Context:** A 3-AZ VPC needs outbound internet access for private subnets. NAT Gateways are billed per-hour whether one shared gateway or one per AZ.

**Decision:** One NAT Gateway per AZ (3 total).

**Alternatives rejected:** One shared NAT Gateway in a single AZ — saves ~$70/month, but creates a real single point of failure: if that AZ has an outage, *all three* AZs lose outbound connectivity simultaneously, even the two healthy ones. This defeats the purpose of multi-AZ deployment for egress traffic specifically.

**Trade-off accepted:** ~$100/month vs ~$33/month for NAT alone. Chosen deliberately because the project's stated goal was demonstrating genuine production patterns, not minimum viable cost — and the operator explicitly confirmed this priority when asked directly.

**What would revisit this:** if this ran as a permanent, budget-constrained non-production environment rather than a demonstration platform, reverting to shared-NAT with the risk explicitly documented would be a legitimate cost optimization.

---

## ADR-002: Karpenter over Cluster Autoscaler

**Context:** The project required node-level autoscaling ("Cluster Autoscaler or a clearly documented equivalent").

**Decision:** Karpenter.

**Alternatives rejected:** Traditional Cluster Autoscaler (ASG-based) — older, slower to react, tied to pre-defined instance-type node groups rather than dynamically selecting the best-fit instance per pending workload.

**Trade-off accepted:** More complex initial IAM/discovery-tag setup (see INCIDENTS.md for the real cost of this complexity — three separate incidents traced back to Karpenter's discovery mechanism) in exchange for faster, more cost-efficient provisioning and the industry direction as of 2026.

**Evidence:** live-tested scale-up (6 pods forced 6 new nodes to provision, Karpenter auto-selected `t4g.small`/Graviton over `t3.small` for cost efficiency) and scale-down via `consolidationPolicy: WhenEmptyOrUnderutilized`.

**What would revisit this:** if operational complexity from Karpenter's discovery-tag coupling to Terraform-managed subnets continued to cause drift incidents at the current rate, a simpler static node-group-only approach would trade elasticity for reliability.

---

## ADR-003: Single cluster, three namespaces — not three clusters

**Context:** Multi-environment (dev/staging/prod) requirement.

**Decision:** One EKS cluster, three namespaces, three separate ArgoCD `Application` resources (not one Application deploying to three places).

**Alternatives rejected:** Three fully separate EKS clusters — the more production-realistic pattern at real company scale, but three control planes ($0.10/hr each, ×3) plus tripled operational surface area is disproportionate for the demonstrated scale.

**Trade-off accepted / explicit boundary documented:** namespace isolation + RBAC + NetworkPolicies provides real separation but does **not** protect against noisy-neighbor resource contention on shared nodes, or a cluster-wide control-plane outage taking down all three environments simultaneously. This boundary is accepted knowingly, not accidentally.

**What would revisit this:** the moment `prod` carries real user traffic or compliance requirements demanding blast-radius isolation from `dev`/`staging`.

---

## ADR-004: Private Route53 zone + private CA, not public domain + Let's Encrypt

**Context:** DNS and TLS requirements, no owned public domain.

**Decision:** ExternalDNS manages a private Route53 hosted zone (`platform.internal`); cert-manager runs as a self-signed two-tier private Certificate Authority (root → issuing CA) rather than requesting public certificates.

**Alternatives rejected:** Buying a domain (~$12/year) — rejected as unnecessary scope expansion for a platform demonstration; the DNS/TLS *mechanisms* are identical regardless of whether the zone is public or private, and the private-zone pattern is itself a real, common enterprise pattern for internal-only services.

**Trade-off accepted:** certificates are not trusted by default by any client outside the platform's own trust chain — proven live via the expected `SSL certificate problem: unable to get local issuer certificate` error when connecting without explicitly trusting the private CA. This is correct behavior, not a limitation to work around.

**What would revisit this:** the moment this platform needs to serve real, public, browser-facing traffic.

---

## ADR-005: Bottlerocket over AL2023 for Karpenter-launched nodes

**Context:** Karpenter-provisioned nodes running AL2023 launched successfully as EC2 instances but never joined the Kubernetes cluster.

**Root cause (full detail in INCIDENTS.md #4):** with `authentication_mode = "API"` (EKS Access Entries only, no `aws-auth` ConfigMap), an `EC2_LINUX` access entry grants only `system:nodes` group membership. AL2023's `nodeadm` bootstrap process additionally requires `system:bootstrappers`, which Access Entries alone cannot grant. `authentication_mode` cannot be downgraded from `API` back to a hybrid mode once set (AWS one-way restriction) — confirmed by a failed `terraform apply` attempting exactly that.

**Decision:** Switch `EC2NodeClass.amiFamily` to `Bottlerocket`.

**Alternatives rejected:** Reintroducing the `aws-auth` ConfigMap hybrid pattern — technically possible but abandoned once the `authentication_mode` downgrade proved impossible; would have required a full cluster rebuild to reach `API_AND_CONFIG_MAP` from a fresh `CONFIG_MAP` state.

**Trade-off accepted:** none of real consequence — Bottlerocket is arguably the stronger choice regardless (minimal, container-purpose-built OS, smaller attack surface) independent of this bug.

**What would revisit this:** if a future Karpenter/EKS version resolves the Access-Entry/`system:bootstrappers` gap for AL2023 specifically.

---

## ADR-006: Single merged repository, not split Terraform/GitOps repos

**Context:** Project began with two repositories (`Production-Platform-on-Kubernetes` for Terraform, a second for GitOps manifests) — the standard pattern at team scale (different review cadence, different blast radius per change type).

**Decision:** Merged into one repository under `infra/` and `gitops/` top-level folders.

**Alternatives rejected:** Keeping them split — correct for a multi-person team, but for a solo-operated portfolio/demonstration project intended to be reviewed end-to-end by a single viewer, one repository that shows the complete system in one place is more legible and more honest about what "senior judgment" means: applying the *right* pattern for the actual scale, not the pattern that looks most impressive.

**Trade-off accepted:** loses the review-cadence separation that would matter at team scale. Explicitly noted as a re-split trigger below.

**What would revisit this:** the moment a second person or a CI/CD pipeline with different approval requirements per repo type is introduced.

---

## ADR-007: Karpenter controller IAM policy sourced from AWS's official CloudFormation template, not hand-written Terraform

**Context:** Karpenter's controller requires an extensive, precise IAM policy (EC2 lifecycle actions, spot pricing lookups, instance profile management) that AWS actively maintains and periodically updates.

**Decision:** Use AWS's official CloudFormation template for the IAM policy content specifically; everything else (the role itself, Pod Identity association, discovery tags) remains in Terraform.

**Alternatives rejected:** Hand-writing the policy in Terraform — rejected as the genuine over-engineering trap in this context: reinventing a security-critical, actively-maintained policy from an authoritative source is not a virtue, it's unnecessary risk (under- or over-permissioning) for no benefit.

**Trade-off accepted:** one deliberate exception to "everything in Terraform," clearly documented rather than silently mixed in.

---

## ADR-008: `terraform-cli` IAM user retains `AdministratorAccess` — deliberately deferred, not overlooked

**Context:** The IAM identity used for all `terraform apply` operations has full account admin rights.

**Decision:** Do not scope this down during initial build.

**Rationale:** hand-crafting a least-privilege policy before all resource types Terraform would touch are known leads to either constant permission-error interruptions or a policy that's really admin-with-extra-steps. Compensating controls applied instead: billing alerts, no credentials ever committed to git (one incident where a key was pasted into chat — rotated immediately, documented in INCIDENTS.md #1), single-operator account.

**What would revisit this:** the moment a second person or automated CI system needs access to this account — at that point, AWS IAM Access Analyzer should generate a real least-privilege policy from actual CloudTrail usage history, not a guess.

