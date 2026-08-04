#!/usr/bin/env bash
# full-rebuild.sh — run after `terraform apply` has already provisioned
# the VPC/EKS/nodes. This handles everything that lives INSIDE the cluster,
# which terraform apply alone does NOT install (Karpenter, ArgoCD, Ingress,
# cert-manager, ExternalDNS, RBAC, PSS, HPA/metrics-server) — those are
# separate systems that don't come back just because the cluster exists again.
set -e

REGION="us-east-1"
CLUSTER="platform-dev-eks"

echo "=== reconnect kubectl ==="
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION"

echo "=== MTU fix (known WSL2 issue, harmless if not needed) ==="
sudo ip link set dev eth0 mtu 1350 2>/dev/null || true

echo "=== Karpenter: check CFN IAM stack, recreate if missing ==="
if ! aws cloudformation describe-stacks --stack-name Karpenter-$CLUSTER --region "$REGION" >/dev/null 2>&1; then
  echo "stack missing, recreating"
  export KV=$(curl -s https://api.github.com/repos/aws/karpenter-provider-aws/releases/latest | grep '"tag_name"' | cut -d'"' -f4 | sed 's/v//')
  curl -fsSL "https://raw.githubusercontent.com/aws/karpenter-provider-aws/v${KV}/website/content/en/preview/getting-started/getting-started-with-karpenter/cloudformation.yaml" -o /tmp/karpenter-cfn.yaml
  aws cloudformation deploy --stack-name Karpenter-$CLUSTER --template-file /tmp/karpenter-cfn.yaml --capabilities CAPABILITY_NAMED_IAM --parameter-overrides "ClusterName=$CLUSTER"
fi

echo "=== Karpenter: install ==="
export KV=$(curl -s https://api.github.com/repos/aws/karpenter-provider-aws/releases/latest | grep '"tag_name"' | cut -d'"' -f4 | sed 's/v//')
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version "${KV}" --namespace kube-system \
  --set settings.clusterName=$CLUSTER \
  --set settings.interruptionQueue=$CLUSTER --wait

echo "=== Karpenter: NodePool + EC2NodeClass (Bottlerocket, Free-Plan-safe instance types) ==="
cat <<'EOF' | kubectl apply -f -
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: default
spec:
  amiFamily: Bottlerocket
  amiSelectorTerms:
    - alias: bottlerocket@latest
  role: KarpenterNodeRole-platform-dev-eks
  subnetSelectorTerms:
    - tags: {karpenter.sh/discovery: platform-dev-eks}
  securityGroupSelectorTerms:
    - tags: {karpenter.sh/discovery: platform-dev-eks}
---
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: default
spec:
  template:
    spec:
      requirements:
        - {key: karpenter.k8s.aws/instance-family, operator: In, values: ["t3","t4g"]}
        - {key: karpenter.k8s.aws/instance-size, operator: In, values: ["micro","small"]}
        - {key: kubernetes.io/arch, operator: In, values: ["amd64","arm64"]}
      nodeClassRef: {group: karpenter.k8s.aws, kind: EC2NodeClass, name: default}
  limits: {cpu: 20}
  disruption: {consolidationPolicy: WhenEmptyOrUnderutilized, consolidateAfter: 30s}
EOF

echo "=== NGINX Ingress (jsdelivr mirror — GitHub Pages CDN is blocked on this network) ==="
kubectl apply -f https://cdn.jsdelivr.net/gh/kubernetes/ingress-nginx@main/deploy/static/provider/aws/deploy.yaml

echo "=== cert-manager ==="
helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
helm repo update
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace --version v1.19.5 \
  --set crds.enabled=true --wait

cat <<'EOF' | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata: {name: selfsigned-root}
spec: {selfSigned: {}}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: {name: platform-ca, namespace: cert-manager}
spec:
  isCA: true
  commonName: platform-root-ca
  secretName: platform-ca-secret
  privateKey: {algorithm: ECDSA, size: 256}
  issuerRef: {name: selfsigned-root, kind: ClusterIssuer}
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata: {name: platform-ca-issuer}
spec: {ca: {secretName: platform-ca-secret}}
EOF

echo "=== ExternalDNS (hand-written, avoids Helm/GitHub Pages dependency) ==="
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata: {name: external-dns}
---
apiVersion: v1
kind: ServiceAccount
metadata: {name: external-dns, namespace: external-dns}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: {name: external-dns}
rules:
  - apiGroups: [""]
    resources: ["services","endpoints","pods","nodes"]
    verbs: ["get","watch","list"]
  - apiGroups: ["extensions","networking.k8s.io"]
    resources: ["ingresses"]
    verbs: ["get","watch","list"]
  - apiGroups: ["discovery.k8s.io"]
    resources: ["endpointslices"]
    verbs: ["get","watch","list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: {name: external-dns-viewer}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: external-dns}
subjects:
  - {kind: ServiceAccount, name: external-dns, namespace: external-dns}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: external-dns, namespace: external-dns}
spec:
  replicas: 1
  selector: {matchLabels: {app: external-dns}}
  template:
    metadata: {labels: {app: external-dns}}
    spec:
      serviceAccountName: external-dns
      containers:
        - name: external-dns
          image: registry.k8s.io/external-dns/external-dns:v0.20.0
          args:
            - --source=ingress
            - --domain-filter=platform.internal
            - --provider=aws
            - --aws-zone-type=private
            - --txt-owner-id=platform-dev-eks
            - --policy=sync
            - --registry=txt
EOF

echo "=== metrics-server (REQUIRED for HPA — was missing, EKS doesn't ship it by default) ==="
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl patch deployment metrics-server -n kube-system --type=json -p="[{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/args/-\",\"value\":\"--kubelet-insecure-tls\"}]"

echo "=== StorageClass: set gp2 as default (EBS addon does not do this automatically) ==="
kubectl patch storageclass gp2 -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' 2>/dev/null || true

echo "=== ArgoCD ==="
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm repo update
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd --set server.service.type=ClusterIP --wait

cat <<'EOF' | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: hello, namespace: argocd}
spec:
  project: default
  source: {repoURL: "https://github.com/velrite/Production-Platform-on-Kubernetes.git", targetRevision: main, path: gitops/apps/hello}
  destination: {server: "https://kubernetes.default.svc", namespace: default}
  syncPolicy:
    automated: {prune: true, selfHeal: true}
    syncOptions: ["CreateNamespace=true"]
EOF

for env in dev staging prod; do
cat <<EOF | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: hello-$env, namespace: argocd}
spec:
  project: default
  source: {repoURL: "https://github.com/velrite/Production-Platform-on-Kubernetes.git", targetRevision: main, path: gitops/environments/$env}
  destination: {server: "https://kubernetes.default.svc", namespace: $env}
  syncPolicy:
    automated: {prune: true, selfHeal: true}
    syncOptions: ["CreateNamespace=true"]
EOF
done

echo "=== RBAC + Pod Security Standards (outside ArgoCD's watched path, applied directly) ==="
kubectl apply -f gitops/cluster-config/rbac.yaml 2>/dev/null || echo "rbac.yaml not found locally, skipping — pull repo first if needed"
kubectl label namespace default pod-security.kubernetes.io/enforce=baseline --overwrite
kubectl label namespace default pod-security.kubernetes.io/audit=restricted --overwrite
kubectl label namespace default pod-security.kubernetes.io/warn=restricted --overwrite

echo "=== HPA — the actual missing piece, created now ==="
cat <<'EOF' | kubectl apply -f -
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: hello
  namespace: default
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: hello
  minReplicas: 2
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 50
EOF

echo "=== waiting for everything to settle ==="
sleep 60

echo "=== FINAL VERIFICATION ==="
echo "--- nodes ---"; kubectl get nodes
echo "--- karpenter ---"; kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter
echo "--- ingress-nginx ---"; kubectl get pods -n ingress-nginx
echo "--- cert-manager ---"; kubectl get pods -n cert-manager
echo "--- external-dns ---"; kubectl get pods -n external-dns
echo "--- metrics-server ---"; kubectl get pods -n kube-system -l k8s-app=metrics-server
echo "--- argocd apps ---"; kubectl get application -n argocd
echo "--- rbac ---"; kubectl get clusterrole developer
echo "--- networkpolicy ---"; kubectl get networkpolicy -n default
echo "--- pod security labels ---"; kubectl get ns default --show-labels
echo "--- hpa ---"; kubectl get hpa -n default
echo "--- pods everywhere ---"
kubectl get pods -n default
kubectl get pods -n dev
kubectl get pods -n staging
kubectl get pods -n prod

echo "=== DONE. metrics-server takes ~1-2 min to start reporting real numbers —"
echo "    if 'kubectl get hpa' shows TARGETS as <unknown>, wait a bit and recheck,"
echo "    don't assume it's broken immediately."
