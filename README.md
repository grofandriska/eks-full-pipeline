# EKS Full Pipeline

Two services (`/api/sa`, `/api/sb`) on EKS behind an nginx DaemonSet and a public NLB, now fully automated with GitHub Actions:

- a change in `src/` builds both images, pushes them to ECR tagged with the commit SHA, and rolls them out to the cluster,
- a change in `terraform/` runs `terraform apply`.

Authentication to AWS uses OIDC (no access keys). Terraform state is stored remotely in S3.

## Repository structure

```
.
├── src/
│   ├── service-a/              # Flask app + Dockerfile
│   └── service-b/
├── terraform/
│   ├── main.tf                 # VPC, EKS (terraform-aws-modules/eks), ECR
│   ├── github-oidc.tf          # IAM role for GitHub Actions + EKS access entry
│   ├── versions.tf             # providers + S3 backend
│   ├── variables.tf, outputs.tf
│   └── modules/
│       ├── infra/              # VPC, subnets, IGW, NAT, route tables
│       └── ecr/                # one ECR repository per service
├── k8s/                        # Kubernetes manifests (Deployments, Services, nginx)
└── .github/workflows/
    ├── build-and-push.yml
    └── terraform-apply.yml
```

## Architecture

```
git push (src/)        → Build and Deploy → ECR (:<commit-sha>) → kubectl set image → EKS
git push (terraform/)  → Terraform Apply  → S3 state → AWS

Internet → NLB → nginx (DaemonSet) → service-a / service-b (ClusterIP) → pods
```

## Workflows

### `build-and-push.yml` – Build and Deploy

Trigger: push to `main` that changes `src/**` (or the workflow file itself).

| Job | What it does |
|---|---|
| `build` | Runs once per service via a `matrix` (`service-a`, `service-b`), in parallel. Logs in to AWS (OIDC) and ECR, builds the image from `src/<service>`, tags it with `github.sha`, pushes it. |
| `deploy` | `needs: build`, so it only starts after both images are pushed. Updates kubeconfig, runs `kubectl set image` for both Deployments, then `kubectl rollout status` so the job fails if the new pods don't become ready. |

Tagging with the commit SHA gives every build a unique, traceable tag, so a new image is always pulled (no stale cached tag).

### `terraform-apply.yml` – Terraform Apply

Trigger: push to `main` that changes `terraform/**` (or the workflow file itself).

Steps: checkout → AWS login (OIDC) → setup Terraform (pinned version) → `fmt -check` → `init` → `validate` → `apply -auto-approve`. All `run` steps execute in `terraform/` via `defaults.run.working-directory`.

## Authentication: OIDC

`terraform/github-oidc.tf` creates one IAM role, `bandi-eks-task-gha`, used by both workflows:

- Trust policy: only this repository's `main` branch may assume it. GitHub sends the `sub` claim with immutable numeric IDs, so the condition is
  `repo:grofandriska@64146340/eks-full-pipeline@1456792318:ref:refs/heads/main`.
- Permissions: `AdministratorAccess` (Terraform manages VPC, EKS, IAM, ECR).
- An EKS access entry with `AmazonEKSClusterAdminPolicy`, so `kubectl` works from the runner.

Repository variables (Settings → Secrets and variables → Actions → Variables):

| Name | Value |
|---|---|
| `AWS_ROLE_ARN` | `terraform output -raw gha_role_arn` |
| `AWS_REGION` | `eu-central-1` |

## Remote state

```hcl
backend "s3" {
  bucket       = "bandi-eks-full-pipeline-tfstate"
  key          = "eks-full-pipeline/terraform.tfstate"
  region       = "eu-central-1"
  use_lockfile = true
}
```

State locking uses S3 native locking (`use_lockfile`, Terraform ≥ 1.10) instead of a DynamoDB table. DynamoDB-based locking is deprecated in recent Terraform versions, and the lockfile approach gives the same protection against concurrent applies without an extra resource.

## Decisions and lessons learned

- **Explicit cluster admins.** `enable_cluster_creator_admin_permissions = true` grants admin to *whoever runs Terraform*. Once the pipeline ran `apply`, the CI role became the "creator" and the local user lost cluster access. Fixed by setting it to `false` and listing both principals explicitly (`access_entries` for the user, `aws_eks_access_entry` for the CI role). The same applies to `kms_key_administrators`.
- **`fmt -check` first.** Unformatted code fails the pipeline before any change reaches AWS.
- **Path filters.** Application and infrastructure changes run independently; changing `src/` never runs Terraform and vice versa.

## Manual bootstrap (one time)

The pipeline deploys image updates; the Kubernetes objects themselves were created once by hand:

```bash
aws s3 mb s3://bandi-eks-full-pipeline-tfstate --region eu-central-1

cd terraform
terraform init
terraform apply
cd ..

aws eks update-kubeconfig --name bandi-eks-task-cluster --region eu-central-1
kubectl apply -f k8s/service-a.yml -f k8s/service-b.yml
kubectl apply -f k8s/nginx-config.yaml
kubectl apply -f k8s/nginx-daemonset.yaml
kubectl apply -f k8s/nginx-service.yml
```

Note: after the first pipeline run the image tags in the cluster are commit SHAs, while `k8s/*.yml` still contains the bootstrap tag. Re-applying those files by hand would roll the services back to the bootstrap image.

## Verify

```bash
kubectl get pods
kubectl get deployment service-a -o jsonpath='{.spec.template.spec.containers[0].image}'

NLB=$(kubectl get svc nginx-proxy -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl http://$NLB/api/sa
curl http://$NLB/api/sb
```

## Teardown

Delete the LoadBalancer Service first: the NLB is created by Kubernetes, not Terraform, and would otherwise block the VPC deletion and keep billing.

```bash
kubectl delete svc nginx-proxy
cd terraform
terraform destroy
```