# Incident Postmortems

Real incidents from this build, in chronological order. Format: What Happened → Root Cause → Fix → Prevention.

---

## Incident 1 — AWS secret access key pasted into an unsecured channel

**Severity:** High (credential exposure)
**What happened:** During initial `aws configure` setup, a real AWS Access Key ID and Secret Access Key were pasted into a chat interface.

**Root cause:** Manual credential entry without a habit of redacting sensitive output before sharing terminal sessions.

**Fix:** Key deactivated and deleted within minutes of exposure. New key generated. A second, pre-existing 19-day-old key on the same IAM user was also rotated out as a precautionary cleanup (unrelated to the exposure, but a live second credential is itself a standing risk once one leak has occurred).

**Prevention:** Established hard rule for the remainder of the build: never paste actual secret values (keys, passwords, tokens) anywhere outside the terminal — only non-sensitive identifiers (ARNs, Account IDs, resource IDs) are safe to share for diagnostics. This rule held for the rest of the project, including a near-repeat with a GitHub Personal Access Token (caught and corrected before commit, see Incident 5).

---

## Incident 2 — AWS Free Plan silently blocked node launches

**Severity:** Medium (16+ minutes lost before root cause found)
**What happened:** EKS managed node group stuck in `CREATING` status indefinitely. `describe-nodegroup` showed no health issues. Zero EC2 instances ever actually launched.

**Root cause:** AWS accounts created after July 15, 2025 are hard-restricted to a specific instance-type allow-list (`t3.micro/small`, `t4g.micro/small`, `c7i-flex.large`, `m7i-flex.large`) for 6 months or until included credits are exhausted. The node group was configured for `t3.medium` — not on the list. This restriction is enforced at the EC2 API level with no quota-increase path; it produced no error visible in EKS's own status fields.

**Diagnostic path that found it:** `aws autoscaling describe-scaling-activities` on the node group's underlying Auto Scaling Group — this surfaced the real `InvalidParameterCombination` error that `describe-nodegroup` never showed.

**Fix:** Changed instance type to `t3.small` (allow-list compliant).

**Prevention:** Documented as a standing constraint on all future instance-type choices, including Karpenter's NodePool requirements, which were built pre-constrained to the same allow-list from the start.

---

## Incident 3 — EKS cluster creator not auto-granted cluster-admin access

**Severity:** Low (quick fix once diagnosed)
**What happened:** `kubectl` returned `"the server has asked for the client to provide credentials"` / `"You must be logged in to the server"` immediately after cluster creation, despite using the same IAM identity that created the cluster.

**Root cause:** Default expectation (per general EKS documentation) is that the cluster creator receives automatic admin access. This did not occur as expected for this cluster's exact creation path.

**Fix:** Explicit `aws_eks_access_entry` + `aws_eks_access_policy_association` Terraform resources added, granting `terraform-cli` `AmazonEKSClusterAdminPolicy` at cluster scope.

**Prevention:** This is now a standard part of every cluster build going forward — never assumed implicit, always explicitly codified in Terraform.

---

## Incident 4 — Karpenter nodes launched in EC2 but never joined the cluster

**Severity:** High (multi-step diagnosis, real architectural fix required)
**What happened:** Karpenter successfully called `RunInstances` — 6 real, `running` EC2 instances confirmed via AWS CLI — but none ever appeared in `kubectl get nodes`, and 6 pending pods stayed pending indefinitely.

**Root cause:** With `authentication_mode = "API"` (EKS Access Entries, no `aws-auth` ConfigMap), an `EC2_LINUX` access entry grants the node role `system:nodes` group membership only. AL2023's `nodeadm` bootstrap process also requires `system:bootstrappers` group membership to complete TLS bootstrap and self-register — Access Entries alone cannot grant this combination. This is a genuine, confirmed gap between EKS's Access Entry system and AL2023's bootstrap requirements as of EKS 1.29+.

**Failed first fix attempt:** tried switching `authentication_mode` to `API_AND_CONFIG_MAP` to reintroduce `aws-auth`. This failed outright — `InvalidParameterException: Unsupported authentication mode update from API to API_AND_CONFIG_MAP` — confirmed that this transition is one-directional only in EKS.

**Actual fix:** Switched Karpenter's `EC2NodeClass.amiFamily` from `AL2023` to `Bottlerocket`, which does not carry the same `system:bootstrappers` requirement. Combined with a plain `EC2_LINUX` access entry for the Karpenter node role. Confirmed live: 6/6 fresh Bottlerocket nodes joined and reached `Ready` within 47-53 seconds.

**Prevention:** Documented in ADR-005. All Karpenter NodePools built after this incident default to Bottlerocket.

---

## Incident 5 — GitHub credential near-miss and public-repo pivot

**Severity:** Medium (credential exposure avoided, real time cost)
**What happened:** ArgoCD failed to sync a newly-private repository (`authentication required: Repository not found`). Attempting to fix it, a GitHub Personal Access Token was typed directly into a multi-line paste that fragmented across terminal lines, and portions of the token were echoed into a shared context before the mistake was caught.

**Root cause:** Multi-line `kubectl create secret` command with backslash line continuations broke apart during paste (terminal interpreted each continuation line as a separate command), exposing partial credential material mid-command.

**Fix:** Revocation of the exposed token was instructed; completion was not recorded (to be verified). Given the repository contained no actual secrets (verified — no credentials in any `.tf` or manifest file all session), the pragmatic decision was made to make the repository public rather than fight PAT-based authentication further under time pressure. ArgoCD sync resolved immediately with zero further authentication configuration.

**Prevention:** Documented as a real, deliberate trade-off (see ADR-006 context) rather than a shortcut — repository content was audited for sensitivity before making this call, not after.

---

## Incident 6 — `terraform destroy` failed with cascading DependencyViolation errors

**Severity:** High (multi-hour resolution)
**What happened:** `terraform destroy` failed repeatedly: Internet Gateway couldn't detach (`mapped public address(es)`), subnets couldn't delete (`has dependencies and cannot be deleted`), and the Route53 private hosted zone couldn't delete (`HostedZoneNotEmpty`).

**Root cause:** Two categories of resources exist in AWS that Terraform never created and therefore doesn't track for cleanup:
1. The AWS Network Load Balancer created by the NGINX Ingress Controller's `Service` (type `LoadBalancer`) — Kubernetes created this via the AWS cloud-controller integration, entirely outside Terraform's awareness.
2. DNS records created by ExternalDNS in the Route53 zone — also created by an in-cluster controller reacting to Kubernetes resources, not by Terraform.

Both left real AWS resources (load balancer, ENIs, DNS records) that blocked deletion of the VPC/subnets/hosted zone Terraform *did* try to destroy.

**Fix:** Built `pre-destroy.sh` — deletes `LoadBalancer`-type Services and Ingress resources first (triggering real cloud-side cleanup by their respective controllers), directly clears any remaining non-NS/SOA Route53 records as a safety net, polls (not a fixed sleep) until the load balancer is actually confirmed gone, drains Karpenter nodes, then runs `terraform destroy` with one automatic retry for AWS eventual-consistency timing.

**Prevention:** `pre-destroy.sh` is now a required first step before any `terraform destroy`, committed to the repository, never optional.

---

## Incident 7 — Karpenter subnet discovery tags repeatedly drifted (3 occurrences)

**Severity:** Medium (recurring — the real signal that triggered a structural fix)
**What happened:** Across three separate rebuild cycles, Karpenter logs showed `"no subnets found"` / `"failed listing instance types"`, and newly-pending pods (ExternalDNS, then later dev/staging/prod app pods) never got new nodes provisioned. Each time, `aws ec2 describe-subnets` confirmed the `karpenter.sh/discovery` tag was simply absent, despite Terraform's own state believing it should exist.

**Root cause:** The tag was managed as a separate `aws_ec2_tag` resource layered on top of the subnet, rather than as part of the subnet resource's own `tags` block. This pattern is known to be fragile around `terraform destroy`/`apply` cycles — a standalone tag resource can lose its association with the parent resource's lifecycle in ways a tag baked into the resource's own creation cannot.

**First two fixes:** Re-running `terraform apply` to reconcile the drift — worked each time, but recurred.

**Structural fix (third occurrence):** Merged the `karpenter.sh/discovery` tag directly into `aws_subnet.private`'s own `tags` block in `networking.tf`, and removed the standalone `aws_ec2_tag.karpenter_subnet_discovery` resource entirely. Tags applied at resource-creation time cannot independently drift the way a bolted-on separate resource can.

**Prevention:** This is the textbook definition of "third time is a pattern, not a coincidence" — documented explicitly as the trigger for moving from patching the symptom to fixing the structure.

---

## Incident 8 — PVC stuck `Pending` — missing default StorageClass on rebuild

**Severity:** Low
**What happened:** After a full cluster rebuild via `full-rebuild.sh`, a `PersistentVolumeClaim` failed to bind: `no persistent volumes available for this claim and no storage class is set`.

**Root cause:** The EBS CSI driver addon recreates the `gp2` StorageClass on every fresh cluster, but *without* the `storageclass.kubernetes.io/is-default-class` annotation — that annotation was applied manually, once, during initial setup, and never captured in the automated rebuild script.

**Fix:** Re-applied the default annotation manually; deleted and recreated the PVC to force a fresh bind attempt.

**Prevention:** Flagged as a required addition to `full-rebuild.sh` — a manual one-time step from initial setup that was never fully automated is a gap, not a one-off.

---

## Incident 9 — GitHub Pages CDN blocked at the network layer (recurring, environment-specific)

**Severity:** Low-Medium (workflow friction, not infrastructure risk)
**What happened:** `helm repo add` for `ingress-nginx` and `argo-helm` (both hosted via GitHub Pages, IP range `185.199.108-111.x`) failed with `Connection refused` — confirmed via raw `curl`/`ping` to the IP directly, ruling out DNS.

**Root cause:** Network-layer block specific to the operator's local environment (WSL2 on Windows), not AWS, not the cluster, not the Helm charts themselves. `google.com` and other non-GitHub-Pages infrastructure connected normally.

**Fix:** Routed chart/manifest installs through alternative CDNs unaffected by the block — `cdn.jsdelivr.net`'s GitHub-repo-mirroring proxy for static manifests (NGINX Ingress, metrics-server), and direct vendor-hosted chart repos (`charts.jetstack.io` for cert-manager) where the chart wasn't GitHub-Pages-hosted at all.

**Related:** a separate WSL2 MTU mismatch caused AWS STS API calls specifically to time out mid-TLS-handshake (`TLS handshake timeout`) — fixed by lowering the WSL2 interface MTU to 1350.

**Prevention:** Both workarounds documented in `full-rebuild.sh` with inline comments explaining *why*, so a future rebuild on the same environment doesn't require re-diagnosing from scratch.

