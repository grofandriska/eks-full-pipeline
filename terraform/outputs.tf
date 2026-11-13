output "ecr_repository_urls" {
  value = module.ecr.repository_urls
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "gha_role_arn" {
  value = aws_iam_role.gha.arn
}