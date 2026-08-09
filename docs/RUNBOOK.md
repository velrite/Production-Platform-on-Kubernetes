# Runbook

## Standing Up the Platform (Full Build)

**Prerequisites:** `aws` CLI configured with credentials for the target account, `terraform` ≥1.15, `kubectl`, `helm`, `git`.

```bash
git clone https://github.com/velrite/Production-Platform-on-Kubernetes.git
cd Production-Platform-on-Kubernetes/infra
terraform init
terraform plan     # review before applying — expect ~53 resources on a fresh account
terraform apply    # ~15-20 minutes; EKS control plane and node group are the long steps
```

**Do not interrupt `terraform apply` mid-run**, especially during EKS cluster creation (10-15 min) — an interrupted control-plane creation leaves a difficult-to-clean partial state. Node group creation is safer to interrupt if genuinely necessary.

Once infra is up:
```bash
cd ..
chmod +x full-rebuild.sh
./full-rebuild.sh
```
This installs, in order: Karpenter (IAM stack check, Helm install, NodePool/EC2NodeClass), NGINX Ingress, cert-manager (+ private CA issuers), ExternalDNS, metrics-server, ArgoCD (+ 4 Applications: `hello`, `hello-dev`, `hello-staging`, `hello-prod`), RBAC, Pod Security Standards labels, and the HPA object.

**Verify before considering the build complete:**
```bash
kubectl get nodes                          # all Ready
kubectl get application -n argocd          # all Synced / Healthy
kubectl get pods -n default -n dev -n staging -n prod   # all Running, not Pending
kubectl get hpa -n default                 # TARGETS showing real % after ~1-2 min, not <unknown>
kubectl get pvc hello-data -n default      # Bound
```

## Tearing Down Safely (Stop Billing)

**Always run `pre-destroy.sh` — never call `terraform destroy` directly.** See INCIDENTS.md #6 for exactly why (real multi-hour failure this exact script exists to prevent).

```bash
chmod +x pre-destroy.sh
./pre-destroy.sh
```

This deletes LoadBalancer Services and Ingress resources first (releasing the real AWS load balancer Terraform never tracked), clears any remaining ExternalDNS-created Route53 records, polls until the load balancer is actually confirmed gone, drains Karpenter nodes, then runs `terraform destroy` with one automatic retry.

**Confirm $0/hour afterward:**
```bash
aws ec2 describe-instances --filters "Name=instance-state-name,Values=running,pending" --query 'Reservations[].Instances[]'
aws eks list-clusters
```
Both should return empty.

## Resuming After a Teardown

```bash
cd infra && terraform apply   # yes
cd .. && ./full-rebuild.sh
```
Rebuilds identically from code — this is the entire point of Infrastructure as Code. Expect the same ~15-20 minute infra step, and note the environment-specific network fixes baked into `full-rebuild.sh` (MTU adjustment, jsdelivr CDN routing) may or may not apply depending on where it's run from.

## Day-2 Operations

**Deploying a change:** commit to `gitops/apps/hello/` (or the relevant `gitops/environments/<env>/` path) and push. ArgoCD's `automated: {prune: true, selfHeal: true}` policy applies it automatically — no manual `kubectl apply` needed for anything ArgoCD watches.

**Manually forcing an ArgoCD sync** (if impatient, or diagnosing a stuck sync):
```bash
kubectl -n argocd annotate application <app-name> argocd.argoproj.io/refresh=hard --overwrite
```

**Checking Karpenter's reasoning** when nodes aren't provisioning as expected:
```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter --tail=30
kubectl get nodeclaims
```
Watch specifically for `"no subnets found"` (discovery tag drift — see INCIDENTS.md #7) or `UnauthorizedOperation` (instance-type allow-list violation — see INCIDENTS.md #2).

**Retrieving the ArgoCD admin password:**
```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```
Delete this initial secret after first login, per ArgoCD's own guidance — not yet done as of this documentation, flagged as an open item.

## Emergency Procedures

**Cluster unreachable / DNS resolution failing for the API endpoint:** almost always means the cluster was rebuilt and the local kubeconfig has a stale endpoint hostname. Fix:
```bash
aws eks update-kubeconfig --name platform-dev-eks --region us-east-1
```

**A pod is stuck `Pending` with no obvious resource pressure:** check pods-per-node ceiling before assuming a compute shortage — see ARCHITECTURE.md "Stress Conditions."

**`terraform apply`/`plan` hangs or times out on AWS API calls specifically (not other domains):** check for a WSL2 MTU mismatch (if running on WSL2) — see INCIDENTS.md #9.

