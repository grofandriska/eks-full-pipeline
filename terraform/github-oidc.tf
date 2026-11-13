data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "gha_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:grofandriska@64146340/eks-full-pipeline@1456792318:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "gha" {
  name               = "${var.project_name}-gha"
  assume_role_policy = data.aws_iam_policy_document.gha_trust.json
}

resource "aws_iam_role_policy_attachment" "gha_admin" {
  role       = aws_iam_role.gha.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_eks_access_entry" "gha" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.gha.arn
}

resource "aws_eks_access_policy_association" "gha" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_eks_access_entry.gha.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope {
    type = "cluster"
  }
}