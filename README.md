# EKS – Two Services behind an nginx Reverse Proxy

Two Flask services (`/api/sa`, `/api/sb`) running on EKS, routed by an nginx DaemonSet and exposed to the internet through an AWS NLB. Infrastructure is managed with Terraform, images are stored in ECR.

## Architecture

```
Internet → NLB → nginx (DaemonSet, one pod per node) → service-a / service-b (ClusterIP) → pods
```

- **VPC**: public subnets (NLB, NAT gateway) and private subnets (EKS nodes). Nodes reach ECR through the NAT gateway.
- **EKS**: managed node group, 2 × `t3.medium`.
- **ECR**: one repository per service (`bandi-eks-task/service-a`, `bandi-eks-task/service-b`).
- **nginx**: runs as a DaemonSet so every node can handle incoming traffic. Its config lives in a ConfigMap, mounted with `subPath` as `/etc/nginx/nginx.conf`, so routing can change without rebuilding an image.
- **Routing**: `/api/sa` → `service-a`, `/api/sb` → `service-b`, `/healthz` → health check for the NLB.

## Folder structure

```
eks-proxy/
├── app/
│   ├── service-a/        # Flask app + Dockerfile
│   └── service-b/
├── ecr/                  # ECR Terraform module
├── k8s/                  # Kubernetes manifests
│   ├── service-a.yml     # Deployment + ClusterIP Service
│   ├── service-b.yml
│   ├── nginx-config.yaml # ConfigMap with routing rules
│   ├── nginx-daemonset.yaml
│   └── nginx-service.yml # LoadBalancer Service → NLB
└── terraform/            # VPC, EKS, ECR
```

All commands below are run from the `eks-proxy/` folder.

To keep commands short, set the registry once per terminal session:

```bash
REGISTRY=362099375729.dkr.ecr.eu-central-1.amazonaws.com
```

## 1. Infrastructure

```bash
cd terraform
terraform init
terraform apply
terraform output ecr_repository_urls
cd ..
```

Connect `kubectl` to the cluster:

```bash
aws eks update-kubeconfig --name bandi-eks-task-cluster --region eu-central-1
kubectl get nodes
```

## 2. Build and push images

Log in to ECR (Podman; with Docker replace `podman` with `docker`):

```bash
aws ecr get-login-password --region eu-central-1 \
  | podman login --username AWS --password-stdin $REGISTRY
```

Build, check, tag and push:

```bash
podman build -t service-a app/service-a
podman build -t service-b app/service-b

podman run --rm service-a pip show flask   # sanity check: dependencies installed

podman tag service-a $REGISTRY/bandi-eks-task/service-a:v3
podman tag service-b $REGISTRY/bandi-eks-task/service-b:v3
podman push $REGISTRY/bandi-eks-task/service-a:v3
podman push $REGISTRY/bandi-eks-task/service-b:v3
```

Check what is in ECR:

```bash
aws ecr list-images --region eu-central-1 --repository-name bandi-eks-task/service-a
```

## 3. Deploy to Kubernetes

Order matters: nginx resolves `service-a` and `service-b` when it starts, so the Services must exist first.

```bash
kubectl apply -f k8s/service-a.yml -f k8s/service-b.yml
kubectl apply -f k8s/nginx-config.yaml
kubectl apply -f k8s/nginx-daemonset.yaml
kubectl apply -f k8s/nginx-service.yml
```

## 4. Verify

```bash
kubectl get pods                  # all pods Running, 1/1
kubectl get svc nginx-proxy       # EXTERNAL-IP = NLB DNS name
```

```bash
NLB=$(kubectl get svc nginx-proxy -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl http://$NLB/api/sa
curl http://$NLB/api/sb
```

The NLB can take 2–3 minutes before it answers.

## 5. Deploy a new version

1. Change the code, rebuild and push with a **new tag** (e.g. `v4`).
2. Update the `image:` tag in `k8s/service-a.yml` / `k8s/service-b.yml`.
3. `kubectl apply -f k8s/service-a.yml -f k8s/service-b.yml`

Why a new tag: nodes cache images by tag. Pushing a fixed image under an existing tag would not be pulled again, so the old version would keep running.

## Troubleshooting

| Symptom | What to check |
|---|---|
| `CrashLoopBackOff` | `kubectl logs <pod>` – the app crashes on start (e.g. missing dependency in `requirements.txt`) |
| `ImagePullBackOff` | `kubectl describe pod <pod>` – wrong image URL/tag, or the image was never pushed |
| `curl` gets no answer | `kubectl get svc nginx-proxy` – wait for the NLB; check nginx logs: `kubectl logs <nginx-pod>` |
| `kubectl` connects to the wrong cluster | run `aws eks update-kubeconfig ...` again |

## Cleanup

Delete images from ECR:

```bash
aws ecr batch-delete-image --region eu-central-1 \
  --repository-name bandi-eks-task/service-a --image-ids imageTag=v1 imageTag=v2
```

Local Podman cleanup:

```bash
podman rm -a -f      # remove all containers
podman rmi -a -f     # remove all images
```

Tear down everything. **Delete the LoadBalancer Service first**: the NLB was created by Kubernetes, not Terraform. If it is still there, `terraform destroy` gets stuck on the VPC and the NLB keeps running (and billing).

```bash
kubectl delete svc nginx-proxy
cd terraform
terraform destroy
```