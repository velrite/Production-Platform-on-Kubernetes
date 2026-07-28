resource "aws_iam_role" "eks_cluster" {
  name = "${var.project_name}-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "eks.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_eks_cluster" "main" {
  name     = local.cluster_name
  role_arn = aws_iam_role.eks_cluster.arn
  version  = "1.35"

  vpc_config {
    subnet_ids              = concat(values(aws_subnet.public)[*].id, values(aws_subnet.private)[*].id)
    endpoint_public_access  = true
    endpoint_private_access = true
    public_access_cidrs     = ["0.0.0.0/0"]
  }

  access_config {
    authentication_mode = "API"
  }

  depends_on = [aws_iam_role_policy_attachment.eks_cluster_policy]

  tags = {
    Name = local.cluster_name
  }
}

resource "aws_iam_role" "eks_nodes" {
  name = "${var.project_name}-eks-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  role       = aws_iam_role.eks_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  role       = aws_iam_role.eks_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "eks_ecr_readonly" {
  role       = aws_iam_role.eks_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_eks_node_group" "system" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "system"
  node_role_arn   = aws_iam_role.eks_nodes.arn
  subnet_ids      = values(aws_subnet.private)[*].id

  instance_types = ["t3.small"]

  scaling_config {
    desired_size = 2
    min_size     = 2
    max_size     = 3
  }

  update_config {
    max_unavailable = 1
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
  ]

  tags = {
    Name = "${var.project_name}-system-nodes"
  }
}

data "aws_caller_identity" "current" {}

resource "aws_eks_access_entry" "admin" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = data.aws_caller_identity.current.arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "admin" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = data.aws_caller_identity.current.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}

resource "aws_eks_addon" "pod_identity_agent" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "eks-pod-identity-agent"
}

resource "aws_ec2_tag" "karpenter_subnet_discovery" {
  for_each    = aws_subnet.private
  resource_id = each.value.id
  key         = "karpenter.sh/discovery"
  value       = local.cluster_name
}

resource "aws_ec2_tag" "karpenter_sg_discovery" {
  resource_id = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
  key         = "karpenter.sh/discovery"
  value       = local.cluster_name
}

resource "aws_iam_role" "karpenter_controller" {
  name = "${var.project_name}-karpenter-controller-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = ["sts:AssumeRole", "sts:TagSession"]
      Effect = "Allow"
      Principal = {
        Service = "pods.eks.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "karpenter_eks_integration" {
  role       = aws_iam_role.karpenter_controller.name
  policy_arn = "arn:aws:iam::681117450689:policy/KarpenterControllerEKSIntegrationPolicy-platform-dev-eks"
}

resource "aws_iam_role_policy_attachment" "karpenter_iam_integration" {
  role       = aws_iam_role.karpenter_controller.name
  policy_arn = "arn:aws:iam::681117450689:policy/KarpenterControllerIAMIntegrationPolicy-platform-dev-eks"
}

resource "aws_iam_role_policy_attachment" "karpenter_interruption" {
  role       = aws_iam_role.karpenter_controller.name
  policy_arn = "arn:aws:iam::681117450689:policy/KarpenterControllerInterruptionPolicy-platform-dev-eks"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_lifecycle" {
  role       = aws_iam_role.karpenter_controller.name
  policy_arn = "arn:aws:iam::681117450689:policy/KarpenterControllerNodeLifecyclePolicy-platform-dev-eks"
}

resource "aws_iam_role_policy_attachment" "karpenter_resource_discovery" {
  role       = aws_iam_role.karpenter_controller.name
  policy_arn = "arn:aws:iam::681117450689:policy/KarpenterControllerResourceDiscoveryPolicy-platform-dev-eks"
}

resource "aws_iam_role_policy_attachment" "karpenter_zonal_shift" {
  role       = aws_iam_role.karpenter_controller.name
  policy_arn = "arn:aws:iam::681117450689:policy/KarpenterControllerZonalShiftPolicy-platform-dev-eks"
}

resource "aws_eks_pod_identity_association" "karpenter" {
  cluster_name    = aws_eks_cluster.main.name
  namespace       = "kube-system"
  service_account = "karpenter"
  role_arn        = aws_iam_role.karpenter_controller.arn

  depends_on = [aws_eks_addon.pod_identity_agent]
}

resource "aws_eks_access_entry" "karpenter_node" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = "arn:aws:iam::681117450689:role/KarpenterNodeRole-platform-dev-eks"
  type          = "EC2_LINUX"
}
