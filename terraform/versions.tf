terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  backend "s3" {
    bucket       = "bandi-eks-full-pipeline-tfstate"
    key          = "eks-full-pipeline/terraform.tfstate"
    region       = "eu-central-1"
    use_lockfile = true
  }
}