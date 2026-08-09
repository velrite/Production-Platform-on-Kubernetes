# Simplicity vs. Production-Realism — What Was Over-Engineered, and Why

Every non-trivial system has a simpler version. This document names the specific places this platform chose complexity over simplicity, prices out what the simpler version would have cost and saved, and states plainly why the complex choice was made anyway — because the honest answer isn't always "this was necessary," and pretending otherwise would undercut the rest of this documentation's credibility.

---

## 1. Three NAT Gateways instead of one

**What was built:** one NAT Gateway per Availability Zone (3 total).

**Simpler alternative:** one shared NAT Gateway.

**Cost/complexity saved by going simple:** ~$70/month, one fewer resource type to reason about, one less thing that can drift (see Incident 7 — this exact class of resource caused three separate real bugs this session).

**What you lose:** if the single NAT Gateway's AZ has an outage, all three AZs lose outbound internet access simultaneously — not just the one that's actually down. A genuine single point of failure hiding inside a "multi-AZ" design.

**Why the complex version was chosen:** the project brief explicitly asked for production patterns, and this is one of the clearest, cheapest ways to demonstrate understanding the difference between "looks multi-AZ" and "actually survives an AZ failure." At $70/month this is a small price for a large, real lesson.

**What I'd do differently on a genuine solo side project, not a demonstration:** go with one shared NAT Gateway, document the accepted risk in one sentence, move on. The 3-NAT choice is correct *for this project's stated purpose*, not universally correct.

---

## 2. Karpenter instead of a static node group

**What was built:** Karpenter, dynamically provisioning and terminating nodes.

**Simpler alternative:** a single static EKS managed node group, sized for expected peak load, no autoscaler at all.

**Cost/complexity saved by going simple:** the entire Karpenter IAM setup (CloudFormation stack, 6 policies, Pod Identity association, discovery tags) disappears. This was directly responsible for Incidents 4 and 7 — real hours lost to Karpenter-specific bugs (the AL2023 bootstrap gap, the recurring subnet-tag drift). A static node group would have hit zero of those.

**What you lose:** no elasticity. You pay for peak capacity 24/7 even at idle, or you under-provision and pods queue during real spikes. No live demonstration of "the platform right-sizes itself."

**Why the complex version was chosen:** Karpenter is the direction the industry has actually moved, and "scaling behavior in action" was an explicit requirement. A static node group can't demonstrate that at all — there'd be nothing to show.

**What I'd do differently on a genuine solo side project:** if the workload is predictable and small (which most side projects are), a static 2-3 node group is genuinely fine, and Karpenter is real over-engineering for that case — the operational complexity isn't earning its keep at that scale.

---

## 3. Three-namespace multi-environment setup (4 ArgoCD Applications) instead of one namespace

**What was built:** separate `dev`/`staging`/`prod` namespaces, each with its own ArgoCD `Application`, deployed independently.

**Simpler alternative:** one namespace, one `Application`, no environment separation at all.

**Cost/complexity saved by going simple:** roughly a third of the ArgoCD configuration disappears, no risk of an environment-specific sync getting confused with another (which did briefly happen — RBAC and NetworkPolicy files living outside the `Application`'s watched `path` required manual intervention, see the ArgoCD-path gap noted in session history).

**What you lose:** no ability to test a change in `dev` before it touches `prod` — which is the entire point of having environments in the first place.

**Why the complex version was chosen:** it was explicitly required, and it's genuinely cheap to demonstrate at this scale — no extra AWS infrastructure cost, purely Kubernetes-namespace and git-path complexity.

**What I'd do differently:** nothing — this is one of the few places where the "simpler" version isn't actually simpler in any way that matters; it just skips a real requirement. Keep this one regardless of scale.

---

## 4. Private CA + TLS instead of plain HTTP

**What was built:** a two-tier private Certificate Authority via cert-manager, issuing real certificates, enforced on the Ingress.

**Simpler alternative:** plain HTTP, no TLS at all.

**Cost/complexity saved by going simple:** zero infrastructure cost either way (cert-manager itself is free); the savings here are purely cognitive — no CA hierarchy to understand, no `ClusterIssuer`/`Certificate` resources to reason about.

**What you lose:** any real understanding of how TLS actually gets provisioned and renewed in a Kubernetes environment — which is one of the most commonly asked-about, commonly misunderstood pieces of real platform work.

**Why the complex version was chosen:** this is cheap complexity buying a lot of real demonstrated capability — genuinely one of the best complexity-to-value ratios in this entire build.

**What I'd do differently:** nothing here either — TLS is a place where "simpler" mostly just means "worse," not "appropriately scoped."

---

## 5. ExternalDNS + private Route53 zone instead of hardcoded IPs

**What was built:** ExternalDNS automatically managing real DNS records in a private hosted zone.

**Simpler alternative:** skip DNS entirely, always reach the app via the raw load-balancer hostname or a manually-noted IP.

**Cost/complexity saved by going simple:** $0.50/month, one fewer IAM role, one fewer controller running.

**What you lose:** the load-balancer's underlying IPs change on every rebuild (confirmed repeatedly this session) — without ExternalDNS, every single rebuild would require manually looking up and re-noting a new address. This is a case where the "complex" option is actually the one that saves *operational* time, not just adds capability.

**Why the complex version was chosen:** both because it was required, and because — unusually for this list — it's not really a net complexity cost once you account for what it replaces (manual IP tracking).

**What I'd do differently:** nothing — this is the rare item where added automation is close to strictly better even at small scale.

---

## 6. RBAC + NetworkPolicies + Pod Security Standards instead of default-open

**What was built:** default-deny networking with explicit exceptions, a scoped `developer` ClusterRole, and baseline Pod Security enforcement.

**Simpler alternative:** default Kubernetes behavior — everything can reach everything, anyone with cluster access has effectively full rights inside it.

**Cost/complexity saved by going simple:** zero AWS cost; the saved complexity is entirely about NetworkPolicy authoring and RBAC scoping — real cognitive overhead, no infrastructure overhead.

**What you lose:** any real security posture at all. This is the one item on this list where I'd argue the "simpler" version isn't a reasonable trade-off at *any* scale, including a genuine solo hobby project — the cost is nearly zero and the exposure from skipping it is real.

**Why the complex version was chosen:** required, and correctly so — this is baseline hygiene, not gold-plating.

**What I'd do differently:** nothing.

---

## Summary — Where the Real Over-Engineering Lives

Ranked by how much of the complexity was genuinely earning its keep versus how much was complexity for complexity's sake, given this project's actual stated goal (demonstrate production capability, not run a real low-traffic side project cheaply):

| Choice | Justified for this project's goal? | Would keep at genuine small-scale? |
|---|---|---|
| RBAC / NetworkPolicy / PSS | Yes, always | Yes |
| TLS / private CA | Yes, cheap and high-value | Yes |
| ExternalDNS | Yes, saves more than it costs | Yes |
| Multi-env (3 namespaces) | Yes, explicit requirement | Only if actually testing changes pre-prod |
| 3 NAT Gateways | Yes, for this project's purpose | **No** — 1 shared NAT is the right call at real small scale |
| Karpenter | Yes, for this project's purpose | **No** — a static node group is the right call at real small scale |

**The honest conclusion:** two real architectural choices in this build (3 NAT Gateways, Karpenter) are genuine over-engineering *relative to what a small real production workload actually needs* — chosen deliberately because the goal was demonstrating the pattern, not minimizing cost for an actual low-traffic app. Everything else on this list either costs nothing extra or actively saves operational effort even at small scale. Knowing which is which — and being able to say so plainly — is itself the point of this document.

---

## Start / Stop the Whole Platform — Clean Reference

**Start (full build, ~20-25 minutes total):**
```bash
cd infra && terraform apply          # yes — ~15-20 min
cd .. && ./full-rebuild.sh           # ~5-8 min — Karpenter, ArgoCD, Ingress,
                                      # cert-manager, ExternalDNS, RBAC, PSS, HPA
```

**Stop (safe teardown, ~5-15 minutes, always in this order):**
```bash
./pre-destroy.sh                     # cleans up LB/DNS/nodes, THEN destroys infra
```

**Verify $0/hour after stopping:**
```bash
aws ec2 describe-instances --filters "Name=instance-state-name,Values=running,pending" --query 'Reservations[].Instances[]'
aws eks list-clusters
```
Both empty = confirmed.

**Never run `terraform destroy` directly** — see Incident 6 for the real multi-hour failure `pre-destroy.sh` exists specifically to prevent.

