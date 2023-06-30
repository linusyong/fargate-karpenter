resource "aws_iam_role" "eks_fargate_profile" {
  name = "eks_fargate_profile"

  assume_role_policy = jsonencode({
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        "Service" : [
          "eks-fargate-pods.amazonaws.com"
        ]
      }
    }]
    Version = "2012-10-17"
  })
}

resource "aws_iam_role_policy_attachment" "eks_fargate_profile" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSFargatePodExecutionRolePolicy"
  role       = aws_iam_role.eks_fargate_profile.name
}

resource "aws_eks_fargate_profile" "karpenter" {
  cluster_name           = aws_eks_cluster.cluster.name
  fargate_profile_name   = "karpenter"
  pod_execution_role_arn = aws_iam_role.eks_fargate_profile.arn

  subnet_ids = [
    for s in aws_subnet.private : s.id
  ]

  selector {
    namespace = "karpenter"
  }
}

resource "aws_iam_role" "karpenter_node" {
  name = "${var.project}-Karpenter-Node"

  assume_role_policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
POLICY
}

resource "aws_iam_instance_profile" "karpenter_instance_profile" {
  name = "karpenter-instance-profile"
  role = aws_iam_role.karpenter_node.name
}

resource "aws_iam_role_policy_attachment" "node_AmazonEKSWorkerNodePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.karpenter_node.name
}

resource "aws_iam_role_policy_attachment" "node_AmazonEKS_CNI_Policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.karpenter_node.name
}

resource "aws_iam_role_policy_attachment" "node_AmazonEC2ContainerRegistryReadOnly" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.karpenter_node.name
}

resource "aws_iam_role_policy_attachment" "node_AmazonSSMManagedInstanceCore" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  role       = aws_iam_role.karpenter_node.name
}

## karpenter IRSA
data "aws_iam_policy_document" "karpenter_policy_document" {
  statement {
    sid = "Karpenter"
    actions = [
      "ssm:GetParameter",
      "iam:PassRole",
      "ec2:DescribeImages",
      "ec2:RunInstances",
      "ec2:DescribeSubnets",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeLaunchTemplates",
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeInstanceTypeOfferings",
      "ec2:DescribeAvailabilityZones",
      "ec2:DeleteLaunchTemplate",
      "ec2:CreateTags",
      "ec2:CreateLaunchTemplate",
      "ec2:CreateFleet",
      "ec2:DescribeSpotPriceHistory",
      "pricing:GetProducts"
    ]
    effect    = "Allow"
    resources = ["*"]
  }

  statement {
    sid     = "ConditionalEC2Termination"
    actions = ["ec2:TerminateInstances"]
    condition {
      test     = "StringLike"
      variable = "ec2:ResourceTag/Name"
      values   = ["*karpenter*"]
    }
    effect    = "Allow"
    resources = ["*"]
  }

  statement {
    sid     = "PassNodeIAMRole"
    actions = ["iam:PassRole"]
    effect  = "Allow"
    # resources = [data.terraform_remote_state.eks.outputs.node_role.arn]
    resources = [aws_iam_role.karpenter_node.arn]
  }

  statement {
    sid       = "EKSClusterEndpointLookup"
    actions   = ["eks:DescribeCluster"]
    effect    = "Allow"
    resources = [aws_eks_cluster.cluster.arn]
  }
}

resource "aws_iam_policy" "karpenter_policy" {
  description = "Grant permissions for 'Karpenter'"
  name        = "karpenter-policy"
  policy      = data.aws_iam_policy_document.karpenter_policy_document.json
}

data "tls_certificate" "this" {
  url = aws_eks_cluster.cluster.identity[0].oidc[0].issuer
}

data "aws_iam_policy_document" "karpenter_assume_role_policy_doc" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type = "Federated"
      identifiers = [
        format("arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${replace(aws_eks_cluster.cluster.identity[0].oidc[0].issuer, "https://", "")}")
      ]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(aws_eks_cluster.cluster.identity[0].oidc[0].issuer, "https://", "")}:sub"
      values   = ["system:serviceaccount:karpenter:karpenter"]
    }
  }
}

resource "aws_iam_role" "karpenter_iam_role" {
  description        = "Role that can be assumed by 'karpenter"
  name               = "karpenter-iam-role"
  assume_role_policy = data.aws_iam_policy_document.karpenter_assume_role_policy_doc.json
  # assume_role_policy = data.terraform_remote_state.eks.outputs.irsa_assume_role_policy_doc.json
}

resource "aws_iam_role_policy_attachment" "karpenter_iam_role_attachment" {
  role       = aws_iam_role.karpenter_iam_role.name
  policy_arn = aws_iam_policy.karpenter_policy.arn
}

resource "aws_iam_openid_connect_provider" "this" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [join("", data.tls_certificate.this.*.certificates.0.sha1_fingerprint)]
  url             = aws_eks_cluster.cluster.identity[0].oidc[0].issuer
}

# EKS Node Security Group
resource "aws_security_group" "eks_nodes" {
  name        = "${var.project}-node-sg"
  description = "Security group for all nodes in the cluster"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name                                           = "${var.project}-node-sg"
    "kubernetes.io/cluster/${var.project}-cluster" = "owned"
  }
}

resource "aws_security_group_rule" "nodes_internal" {
  description              = "Allow nodes to communicate with each other"
  from_port                = 0
  protocol                 = "-1"
  security_group_id        = aws_security_group.eks_nodes.id
  source_security_group_id = aws_security_group.eks_nodes.id
  to_port                  = 65535
  type                     = "ingress"
}

resource "aws_security_group_rule" "nodes_cluster_inbound" {
  description              = "Allow worker Kubelets and pods to receive communication from the cluster control plane"
  from_port                = 1025
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_nodes.id
  source_security_group_id = aws_security_group.eks_cluster.id
  to_port                  = 65535
  type                     = "ingress"
}