# Security Architecture

## Identity and Access Management (AWS)

Six purpose-scoped IAM roles, no shared/generic roles:

| Role | Used by | Permissions |
|---|---|---|
| `platform-eks-cluster-role` | EKS control plane | `AmazonEKSClusterPolicy` only |
| `platform-eks-node-role` | Static system node group | Worker node policy, CNI policy, ECR read-only |
| `platform-karpenter-controller-role` | Karpenter controller pod (Pod Identity) | 6 discrete policies from AWS's official Karpenter CFN template (EKS integration, IAM integration, interruption handling, node lifecycle, resource discovery, zonal shift) |
| `KarpenterNodeRole-platform-dev-eks` | Karpenter-launched EC2 instances | Standard node policies, sourced from the same CFN template |
| `platform-external-dns-role` | ExternalDNS pod (Pod Identity) | `route53:ChangeResourceRecordSets` scoped to exactly one hosted zone ARN — not `*` |
| `platform-ebs-csi-role` | EBS CSI driver pod (Pod Identity) | `AmazonEBSCSIDriverPolicy` |

**Authentication mechanism:** EKS Access Entries (`authentication_mode = "API"`) — the modern replacement for the `aws-auth` ConfigMap — used for all human/IAM-principal access. Pod Identity (not IRSA/OIDC) used for all in-cluster service account → IAM role bindings.

**Known deferred risk:** `terraform-cli`, the IAM user used for all provisioning, retains `AdministratorAccess`. See ADR-008 for the explicit rationale and compensating controls (billing alerts, no committed credentials, single-operator account). This is a documented, deliberate deferral — not an oversight.

## In-Cluster RBAC

A `developer` `ClusterRole` demonstrates least-privilege Kubernetes RBAC:
```yaml
rules:
  - apiGroups: ["", "apps", "networking.k8s.io"]
    resources: ["pods", "deployments", "services", "ingresses", "configmaps"]
    verbs: ["get", "list", "watch", "create", "update", "patch"]
  - apiGroups: [""]
    resources: ["pods/log", "pods/exec"]
    verbs: ["get", "create"]
```
Deliberately **excludes `delete`** — a developer can deploy and iterate but cannot destroy resources outright; destructive actions require a higher privilege tier.

## Network Segmentation

Default-deny NetworkPolicy at the namespace level, with one explicit, narrow exception:
```yaml
# Deny everything by default
podSelector: {}
policyTypes: [Ingress]
---
# Explicit exception: only the ingress controller, only port 80
podSelector: {matchLabels: {app: hello}}
ingress:
  - from:
      - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: ingress-nginx}}
    ports: [{protocol: TCP, port: 80}]
```
**Status: NOT VERIFIED.** The policy objects exist, but enforcement was never confirmed. During the HPA test, pods in the same namespace reached the app despite the default-deny rule, which suggests the CNI was not enforcing policy. A block test from a non-allowed namespace is required before this control can be claimed.

## Pod Security Standards

Namespace-level enforcement via the built-in Pod Security Admission controller (successor to the deprecated PodSecurityPolicy):
- `enforce: baseline` — blocks genuinely dangerous configurations now (host network/PID/IPC access, privilege escalation) without risk of breaking existing workloads.
- `audit: restricted`, `warn: restricted` — surfaces what *would* break under the strictest tier, without enforcing it yet. This gives visibility before tightening enforcement, rather than an unplanned outage from jumping straight to `restricted` enforcement.

## Transport Security (TLS)

Two-tier private Certificate Authority via cert-manager:
1. Self-signed root (`selfsigned-root` ClusterIssuer) — issues exactly one certificate: the platform's own root CA.
2. `platform-ca-issuer` — signs all subsequent certificates using that root, meaning every certificate this platform issues shares one common, trustable-if-imported chain.

**Why this matters over flat self-signed certs:** a flat self-signed issuer creates an unrelated root per certificate — no shared trust. The two-tier pattern means trusting the root once (e.g., importing it into a browser's trust store) makes every future certificate this platform issues automatically trusted, matching how real enterprise internal CAs operate.

## Secrets Handling

- No credentials committed to any repository at any point (audited across all `.tf` and manifest files).
- Two real near-misses during this build (AWS key, GitHub PAT) — both caught, both rotated immediately, both documented in `INCIDENTS.md` rather than hidden.
- Kubernetes `Secret` objects used for cert-manager's CA private key and ArgoCD's admin credential, scoped to their respective namespaces via standard Kubernetes RBAC (no cross-namespace secret access granted anywhere in this build).

## Known Gaps (Explicit, Not Hidden)

- No image scanning / admission control (e.g., no policy blocking unscanned or untrusted container images from running).
- No secrets manager integration (AWS Secrets Manager / External Secrets Operator) — Kubernetes-native `Secret` objects only, which are base64-encoded, not encrypted at rest by default without additional EKS envelope encryption configuration (not yet enabled on this cluster).
- No audit logging pipeline configured for the EKS control plane (CloudWatch/EKS control plane logging not yet enabled).

These are listed explicitly rather than omitted — see `docs/ROADMAP_AND_GAPS.md` for what a next phase addressing these would look like.

