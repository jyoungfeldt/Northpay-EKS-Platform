# NorthPay Payments Platform on EKS

[![CI](https://github.com/jyoungfeldt/northpay-eks-platform/actions/workflows/ci.yml/badge.svg)](https://github.com/jyoungfeldt/northpay-eks-platform/actions/workflows/ci.yml)
[![Terraform](https://github.com/jyoungfeldt/northpay-eks-platform/actions/workflows/terraform.yml/badge.svg)](https://github.com/jyoungfeldt/northpay-eks-platform/actions/workflows/terraform.yml)

A production-style Amazon EKS platform running a small payments API, built the way a fintech platform team would build it: GitOps deployments, security policies, autoscaling, and safe canary releases — all on Terraform, all without long-lived credentials.

> **Related project:** [NorthPay CloudOps Agent](https://github.com/jyoungfeldt/northpay-cloudops-agent) — an AI agent that monitors this cluster for security findings and cost anomalies.

---

## The Problem

NorthPay processes payments and needs a platform that is:

- **Secure by default** — no root containers, registry-restricted images, namespaced RBAC
- **Safe to deploy** — canary releases with automatic rollback, not big-bang deployments
- **Observable** — metrics, dashboards, and alerts so on-call engineers know what's wrong
- **Cost-efficient** — Spot capacity via Karpenter, single `terraform destroy` when idle
- **GitOps** — cluster state lives in Git; no manual `kubectl apply` in production

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         GitHub                                   │
│  ┌──────────┐  push  ┌──────────┐  image  ┌──────────────────┐  │
│  │ Dev push │───────▶│    CI    │────────▶│  ECR repository  │  │
│  └──────────┘        │ (test,   │         └──────────────────┘  │
│                      │  scan,   │  update manifest              │
│                      │  build)  │─────────────────┐             │
│                      └──────────┘                 ▼             │
│                                         ┌──────────────────┐    │
│                                         │  GitOps repo     │    │
│                                         │  (k8s manifests) │    │
│                                         └────────┬─────────┘    │
└──────────────────────────────────────────────────┼──────────────┘
                                                   │ sync
┌──────────────────────────────────────────────────▼──────────────┐
│  AWS (us-east-1)                                                 │
│                                                                  │
│  VPC (3 AZs)                                                     │
│  ├── Public subnets   → ALB (AWS Load Balancer Controller)       │
│  └── Private subnets  → EKS nodes (Karpenter, Spot)             │
│                                                                  │
│  EKS Cluster                                                     │
│  ├── platform ns:  Argo CD, Argo Rollouts, Kyverno               │
│  │                 External Secrets, AWS LBC, Karpenter          │
│  │                 Amazon Managed Prometheus agent               │
│  └── ledger ns:    Ledger API (FastAPI)                          │
│                    HPA (cpu + rps), NetworkPolicy                │
│                                                                  │
│  Aurora Serverless v2 (PostgreSQL)  ← EKS Pod Identity          │
│  Secrets Manager  ← External Secrets Operator                   │
│  Amazon Managed Prometheus + Grafana                             │
└──────────────────────────────────────────────────────────────────┘
```

---

## Stack

| Layer | Implementation |
|---|---|
| Network | Terraform VPC, 3 AZs, private node subnets, VPC endpoints |
| Cluster | EKS via `terraform-aws-modules/eks`, Karpenter, Spot capacity |
| Service | Ledger API — FastAPI: `POST /payments`, `GET /balance/{account}` |
| Database | Aurora Serverless v2 (PostgreSQL) via EKS Pod Identity |
| Secrets | AWS Secrets Manager → pods via External Secrets Operator |
| Ingress | AWS Load Balancer Controller (ALB + TLS via ACM) |
| CI | GitHub Actions: pytest → Trivy scan → ECR push → manifest update |
| CD | Argo CD (GitOps) + Argo Rollouts (canary with AnalysisTemplate) |
| Security | Kyverno policies, NetworkPolicy, namespaced RBAC |
| Scaling | HPA on CPU/RPS + Karpenter node autoscaling |
| Observability | Amazon Managed Prometheus, Managed Grafana, CloudWatch logs |

---

## Design Decisions

### AWS Load Balancer Controller over ingress-nginx
`ingress-nginx` was retired in March 2026. AWS LBC provisions an ALB natively, integrates with ACM for TLS, and supports target-group binding for weighted canary traffic routing. The trade-off is AWS vendor lock-in, acceptable given this platform is EKS-native throughout.

### Karpenter over Managed Node Groups
Karpenter selects instance types at launch time, which makes it significantly better at finding Spot capacity and bin-packing workloads. Managed Node Groups can't consolidate. The trade-off is operational complexity: Karpenter requires a `NodePool` and `EC2NodeClass` per workload profile.

### Argo Rollouts canary over blue/green
Canary sends 10% of traffic to the new version before promoting. A bad deploy rolls back before it reaches 100% of traffic. Blue/green is simpler but doubles the compute cost during the transition window.

### Aurora Serverless v2 over RDS
Scales ACUs down to 0.5 when idle — important for a demo project that runs intermittently. The trade-off is slightly higher per-unit cost than a provisioned instance at steady load.

### EKS Pod Identity over IRSA
Pod Identity is the current AWS recommendation for associating IAM roles with pods. It requires no annotation on the service account and no OIDC trust-policy per role. IRSA still works and is used for EBS CSI where Pod Identity isn't yet supported.

---

## Prerequisites

- AWS account
- Terraform ≥ 1.8
- `kubectl`, `helm`, `argocd` CLI
- Route 53 hosted zone (for TLS via ACM)
- S3 bucket + DynamoDB table for Terraform state (see [bootstrapping](#deploy))

### GitHub Secrets

| Secret | Value |
|---|---|
| `AWS_ROLE_ARN` | IAM role ARN assumed via GitHub OIDC (no long-lived keys) |
| `AWS_REGION` | e.g. `us-east-1` |
| `ECR_REPOSITORY` | ECR repo URI (output from Terraform) |
| `CLUSTER_NAME` | EKS cluster name |

---

## Deploy

```bash
# 1. Create Terraform state backend (one-time)
aws s3 mb s3://northpay-tfstate-dev --region us-east-1
aws dynamodb create-table --table-name northpay-tfstate-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST --region us-east-1

# 2. Deploy infrastructure
cd terraform/environments/dev
terraform init
terraform apply

# 3. Configure kubectl
aws eks update-kubeconfig --name northpay-dev --region us-east-1

# 4. Bootstrap Argo CD (one-time)
kubectl apply -k kubernetes/platform/argocd
kubectl apply -f kubernetes/platform/apps/app-of-apps.yaml

# 5. Argo CD syncs everything else from Git automatically
argocd app list
```

Every subsequent deploy is a Git push — CI builds and pushes the image, updates the Kustomize manifest, and Argo CD deploys it as a canary.

---

## Demo

📹 [Watch the 4-minute demo](https://www.loom.com/YOUR_LINK) — canary deploy, autoscaling under load, and Kyverno blocking a root container.

### Canary deploy
```bash
git commit -m "feat: add request tracing header"
git push
kubectl argo rollouts get rollout ledger-api -n ledger --watch
```

### Autoscaling under load
```bash
k6 run scripts/load-test.js
kubectl get pods -n ledger -w   # pods scale out
kubectl get nodes -w            # Karpenter provisions new nodes
```

### Kyverno blocks a root container
```bash
kubectl apply -f scripts/bad-pod.yaml
# Error from server: admission webhook denied the request:
# Containers must run as non-root.
```

---

## Cost

| Resource | Approx. monthly cost |
|---|---|
| EKS control plane | $73 |
| EC2 nodes (2× m6g.large Spot) | ~$25 |
| Aurora Serverless v2 (idle) | ~$5–10 |
| ALB | ~$5 |
| NAT Gateway | ~$8 |
| Amazon Managed Prometheus | ~$2–5 |
| **Running continuously** | **~$120–130/month** |
| **Destroy when idle** | **~$30–60/month** |

Run `terraform destroy` when not working or demoing. The EKS control plane at $0.10/hr is the main driver.

---

## Teardown

```bash
# 1. Remove Kubernetes resources first (lets LBC clean up the ALB)
kubectl delete -f kubernetes/platform/apps/app-of-apps.yaml
argocd app delete --all
sleep 60

# 2. Destroy infrastructure
cd terraform/environments/dev
terraform destroy
```

> ⚠️ Always delete in this order. Running `terraform destroy` first leaves the ALB and its security groups orphaned, which blocks VPC deletion.

---

## Repository Structure

```
northpay-eks-platform/
├── .github/workflows/
│   ├── ci.yml              # test → Trivy → ECR push → manifest update
│   └── terraform.yml       # plan on PR, apply on merge
├── apps/
│   └── ledger-api/         # FastAPI source, Dockerfile, pytest suite
├── kubernetes/
│   ├── apps/ledger-api/    # Kustomize base + dev overlay
│   └── platform/           # Argo CD, Kyverno, app-of-apps
├── scripts/
│   ├── load-test.js        # k6 load test
│   └── bad-pod.yaml        # Kyverno demo artifact
└── terraform/
    ├── modules/            # vpc, eks, karpenter, alb-controller, aurora, observability
    └── environments/dev/
```
