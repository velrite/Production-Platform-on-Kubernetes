# Production Platform on Kubernetes

**A three-AZ EKS platform provisioned with Terraform, delivered through GitOps, and tested for failure (node termination, autoscaling, rolling update).**

> **Evidence status.** The AWS environment was built, tested and destroyed between 2026-07-26 and 2026-08-09. The account's Free Plan credits then ran out and the account was closed, so nothing can be run live. This README rests on repository evidence (see [Evidence](#evidence)). Where something was not proven, it says so.

**Labels:** `VERIFIED` observed in real terminal output at build time · `PARTIAL` · `NOT VERIFIED` · `NOT BUILT` · `KNOWN LIMITATION`
Test outputs were transcribed into `docs/TESTING_AND_VALIDATION.md` and committed on 2026-08-09. They are not screenshots of the live cluster.

---

## 1. The question this project answers

Can one engineer build **and operate** a production-shaped Kubernetes platform: provision it from code, deploy to it from Git, scale it, secure it, watch it fail, and tear it down without leaving billing resources behind?

Scope: solo operator, AWS `us-east-1`, no owned domain (private DNS zone plus private CA), AWS Free Plan constraints (instance allow-list, finite credits).

## 2. Architecture

~~~mermaid
flowchart TB
    Eng["Engineer"] -->|terraform apply| TF["Terraform"] --> AWS["VPC, EKS, IAM, Route53, EBS CSI"]
    Eng -->|git push| Git[("GitHub: gitops/")]
    subgraph VPC["VPC, 3 AZs, per-AZ NAT"]
        subgraph EKS["EKS v1.35"]
            Argo["ArgoCD"] --> Apps["hello: default, dev, staging, prod"]
            Karp["Karpenter"] --> Nodes["Bottlerocket nodes"]
            HPA["HPA + metrics-server"] --> Apps
            Cert["cert-manager (private CA)"] --> Ing["NGINX Ingress"]
            Ing --> Apps
            EDNS["ExternalDNS"]
        end
    end
    Git -.->|watched| Argo
    EDNS --> R53[("Route53 private zone")]
    Client(("Client")) -->|HTTPS| NLB["NLB"] --> Ing
~~~

**The design rule that explains most of the incidents:** Terraform owns what exists in AWS, ArgoCD owns what runs in Kubernetes, and neither knows about the other. Controllers inside the cluster create real AWS resources (load balancers, DNS records, EC2 instances) that Terraform never tracks. Most failures lived in that gap.

Full detail: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) · [`docs/ADR.md`](docs/ADR.md)

## 3. What was built

| Capability | Status | Basis |
|---|---|---|
| 3-AZ VPC, 3 NAT gateways, public/private subnets | VERIFIED | plan and apply output, `infra/networking.tf` |
| EKS v1.35 + managed system node group (2 x t3.small) | VERIFIED | nodes Ready, kube-system pods Running |
| Karpenter (6 nodes launched and Ready in ~50 s) | VERIFIED | controller logs, `describe-instances` |
| ArgoCD GitOps, 4 Applications | VERIFIED | Synced/Healthy |
| NGINX Ingress + NLB | VERIFIED | HTTP response through the NLB |
| cert-manager private CA | VERIFIED | Certificate Ready; untrusted-issuer error without `-k` |
| ExternalDNS + Route53 private zone | VERIFIED | controller logs, record listing, in-cluster lookup |
| HPA | VERIFIED | `SuccessfulRescale` events (2 -> 6 -> 4) |
| Persistent volume bound | VERIFIED | PVC `Bound` |
| Data surviving a pod/node replacement | NOT VERIFIED | never tested |
| RBAC | PARTIAL | role defined, never bound or exercised |
| NetworkPolicy enforcement | NOT VERIFIED | same-namespace pods reached the app despite default-deny; probably not enforced |
| Pod Security | PARTIAL | `warn: restricted` fired; `enforce: baseline` never tested against a violating pod |
| Environments (dev/staging/prod) | PARTIAL | separate namespaces, but controls exist only in `default` |
| CI pipeline | NOT BUILT | |
| Monitoring, alerting, central logs | NOT BUILT | control-plane logging verified disabled |
| Backups | NOT BUILT | |
| AZ-failure test, rollback test, valid load test, EKS upgrade | NOT VERIFIED | |

## 4. Measured results

Transcribed from terminal output at test time (`docs/TESTING_AND_VALIDATION.md`).

| Test | Result | Caveat |
|---|---|---|
| Node failure | 2/2 pods Ready in **101 s** on a newly provisioned node | both replicas landed on the same new node (no anti-affinity) |
| Rolling update under traffic | **0 non-200 of 18** requests | small sample; each request paid a TLS handshake |
| HPA under load | scaled **2 -> 6 -> 4** | target lowered to 10% to force an event; at 50% CPU peaked at 49% and correctly did not scale |
| Karpenter scale-up | **6** nodeclaims, 6 instances, Ready in ~47-53 s | scale-down (consolidation) not watched end to end |
| Load test (latency percentiles) | **invalid, discarded** | all workers failed; likely a stale hardcoded load-balancer hostname after a rebuild |

## 5. Failure catalogue

Nine incidents are written up in [`docs/INCIDENTS.md`](docs/INCIDENTS.md). The ones that taught the most:

| Symptom | Real cause | Where it was found |
|---|---|---|
| Node group `CREATING` for 16+ min, zero instances, EKS reports healthy | Free Plan blocks `t3.medium` | Auto Scaling Group activity log, one layer below EKS |
| Karpenter instances `running` in EC2 but never join | AL2023 needs a group Access Entries cannot grant; `authentication_mode` cannot be moved back | Fixed by switching to Bottlerocket |
| `no subnets found`, three rebuilds in a row | discovery tag as a separate `aws_ec2_tag` resource drifted | Structural fix: tag inside the subnet resource |
| `terraform destroy` failed with `DependencyViolation` and `HostedZoneNotEmpty` | NLB and DNS records created by controllers, unknown to Terraform | `pre-destroy.sh` |
| PVC stuck `Pending` after rebuild | default StorageClass annotation was a manual step | scripted in `full-rebuild.sh` |
| Account closed | credits consumed; Cost Explorer showed about $0, so spend alerts never fired | credit balance needs its own alarm |

Credential exposures (an AWS key and a GitHub token pasted into chat) are documented as incidents. The AWS key was revoked the same session. GitHub token revocation was instructed but is not confirmed in this record.

## 6. Decisions worth defending

Eight ADRs in [`docs/ADR.md`](docs/ADR.md). Two choices are deliberate over-engineering for a project this size:

- **Three NAT gateways** cost about $70/month more than one, and remove a cross-AZ single point of failure. For a small hobby workload, one is the right call.
- **Karpenter** brought three incidents. For a small steady workload, a static node group is the right call.

See [`docs/SIMPLICITY_VS_PRODUCTION_TRADEOFFS.md`](docs/SIMPLICITY_VS_PRODUCTION_TRADEOFFS.md).

## 7. Limits (read before relying on anything above)

- No CI, no observability, no backups, no alerting.
- NetworkPolicy isolation is **unproven**; RBAC is **unbound**.
- The three environments are not policy-equivalent.
- EKS API endpoint is public (`0.0.0.0/0`), protected by IAM only; `terraform-cli` holds `AdministratorAccess` (ADR-008).
- Several inputs are unpinned (NGINX manifest `@main`, ArgoCD chart, Bottlerocket `@latest`).
- `eks.tf` hardcodes the account ID in some policy ARNs, and expects the Karpenter CloudFormation stack to exist before `terraform apply`. A fresh account would fail until both are fixed.
- Cost: about $0.30-0.35/hr while running (list prices, not verified against billing). The earlier $5-6.50 total is a runtime estimate, not a measured bill.
- Git history is thin: the working copy was lost mid-build and files were re-committed from backup. Commit dates support the timeline but do not by themselves prove it.

## 8. Evidence

Index with what each item proves and does not prove: [`docs/EVIDENCE.md`](docs/EVIDENCE.md). Images are in [`docs/evidence/`](docs/evidence/).

| Evidence | Shows |
|---|---|
| Git commit timeline, GitHub commit graph | 17 commits over 7 days, 2026-07-26 to 2026-08-09 |
| Repo structure and size | 777 lines of Terraform and scripts |
| Terraform static validation | code is valid; **not** proof it was applied |
| Test-results commit history | results committed in `34a1c0d`; **not** proof of when tests ran |
| Script syntax check | scripts parse; no lint claim |

**Not yet captured (needs the AWS account reactivated, deadline 2026-12-03):** S3 state-version history, billing lines for EKS/NAT, CloudTrail create/delete events. CloudTrail keeps 90 days, so earlier events may already be gone.

## 9. Repository map

~~~
infra/            Terraform: backend, provider, networking, eks, dns, storage
gitops/           apps/hello, environments/{dev,staging,prod}, cluster-config/rbac.yaml
full-rebuild.sh   in-cluster installs after terraform apply
pre-destroy.sh    safe teardown (never run terraform destroy directly)
docs/             architecture, ADRs, security, incidents, runbook, testing, cost, gaps, evidence
~~~

## 10. Rebuild and teardown

Prerequisites: AWS account (paid, or Free Plan limits understood), `aws`, `terraform` >= 1.15, `kubectl`, `helm`.

1. Create the S3 state bucket by hand and set its name in `infra/backend.tf`.
2. Deploy the Karpenter IAM CloudFormation stack first (see Limits).
3. `cd infra && terraform init && terraform plan && terraform apply` (about 15-20 min).
4. `./full-rebuild.sh` (about 5-8 min).
5. Tear down with `./pre-destroy.sh`, then confirm no instances and no clusters remain.

Details: [`docs/RUNBOOK.md`](docs/RUNBOOK.md).
