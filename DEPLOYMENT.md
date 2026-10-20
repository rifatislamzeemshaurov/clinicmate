# ClinicMate — Deployment Guide (AWS + Terraform)

This guide covers deploying ClinicMate to AWS with a single command, updating clinic data, and tearing everything down with a single command.

```
Browser ──HTTPS──► CloudFront ─┬─ "/" ─────────────────────────────► S3 (static Next.js frontend)
                               └─ "/chat", "/health",
                                  "/conversation/*" ──► ALB ──► ECS Fargate (FastAPI in Docker)
                                                                   ├─ image from ECR
                                                                   ├─ chat memory in S3
                                                                   └─ OpenAI API
```

---

## 1. One-time prerequisites

| Tool | Check |
|---|---|
| AWS CLI v2, configured (`aws configure`) | `aws sts get-caller-identity` |
| Terraform ≥ 1.0 | `terraform -version` |
| Docker Desktop (running) | `docker info` |
| Node.js 20+ and npm | `node -v` |
| An OpenAI API key | — |

The AWS identity needs permission to manage ECR, ECS, EC2 (security groups, default VPC lookups), Elastic Load Balancing, IAM roles, S3, CloudFront, CloudWatch Logs and, for custom domains only, Route 53 and ACM.

Resources are created in the region set by `aws configure` (for example `ap-south-1`). The account's **default VPC** must exist.

## 2. Configure before deploying

### 2.1 OpenAI key: `backend/.env`

```bash
cp backend/.env.example backend/.env
```

Set `OPENAI_API_KEY=sk-...`. This file is git-ignored. The deploy scripts read the key from here and pass it to Terraform as `TF_VAR_openai_api_key`, so it is never written into any Terraform file.

### 2.2 Clinic data: `backend/clinic_data.txt`

This is the only file a clinic needs to edit. Paste in the doctors, specialties, what each doctor treats, wards, visiting hours, fees, booking numbers, diagnostic tests and prices, booking steps and policies. ClinicMate answers **only** from this file.

The file is baked into the Docker image, so after editing it, run the deploy command again to publish the change.

## 3. Deploy: one command

From the `clinicmate/` folder:

```bash
# macOS / Linux / Git Bash
./scripts/deploy.sh dev          # or: test | prod
```

```powershell
# Windows PowerShell
.\scripts\deploy.ps1 -Environment dev     # or: test | prod
```

What the script does, automatically:

1. Verifies Docker is running and `OPENAI_API_KEY` is set.
2. `terraform init` and selects (or creates) the workspace for the environment.
3. Bootstraps the ECR repository.
4. Builds the backend Docker image and pushes it to ECR with a timestamp tag.
5. `terraform apply` creates or updates every resource and rolls ECS to the new image.
6. Waits until the ECS service is healthy behind the load balancer.
7. Builds the Next.js frontend and syncs it to the S3 website bucket.
8. Invalidates the CloudFront cache and prints the live URL.

The first deploy takes roughly 10–15 minutes, mostly CloudFront propagation. Later deploys are faster.

Example output:

```
Deployment complete!
App URL        : https://dxxxxxxxxxxxx.cloudfront.net
ECS cluster    : clinicmate-dev-cluster
ECS service    : clinicmate-dev-api
```

### Resources created (per environment)

All names are prefixed `clinicmate-<env>-`:

| Resource | Name |
|---|---|
| ECR repository | `clinicmate-<env>-api` |
| ECS cluster / service / task | `clinicmate-<env>-cluster`, `clinicmate-<env>-api` |
| Application Load Balancer + target group | `clinicmate-<env>-alb`, `clinicmate-<env>-api-tg` |
| Security groups | `clinicmate-<env>-alb-sg`, `clinicmate-<env>-ecs-sg` |
| IAM roles | `clinicmate-<env>-ecs-execution-role`, `clinicmate-<env>-ecs-task-role` |
| S3 buckets | `clinicmate-<env>-frontend-<account-id>`, `clinicmate-<env>-memory-<account-id>` |
| CloudWatch log group | `/ecs/clinicmate-<env>-api` |
| CloudFront distribution | tagged `Project=clinicmate` |
| *Custom domain only:* ACM certificate + Route 53 records | for `domain_name` (and `www.` for apex domains) |

## 4. Destroy: one command

```bash
./scripts/destroy.sh dev                  # macOS / Linux / Git Bash
```

```powershell
.\scripts\destroy.ps1 -Environment dev    # Windows PowerShell
```

The script empties both S3 buckets (frontend and chat memory), then runs `terraform destroy` for that environment. The ECR repository is force-deleted along with its images. CloudFront deletion can take several minutes.

To also remove the empty workspace afterwards:

```bash
cd terraform
terraform workspace select default
terraform workspace delete dev
```

## 5. Custom domain (one command)

Serve ClinicMate on the clinic's own domain with free, auto-renewing HTTPS:

```bash
./scripts/deploy.sh prod yourclinic.com          # → https://yourclinic.com + https://www.yourclinic.com
./scripts/deploy.sh prod chat.yourclinic.com     # → https://chat.yourclinic.com (main website untouched)
./scripts/deploy.sh prod clinic.com.bd           # country-code domains work too
```

```powershell
.\scripts\deploy.ps1 -Environment prod -Domain yourclinic.com
```

### What happens automatically

| Step | Done by |
|---|---|
| Find the Route 53 hosted zone that contains the domain (walks up from `chat.clinic.com.bd` to `clinic.com.bd`) | deploy script |
| Request a free **SSL/TLS certificate** from AWS Certificate Manager (`us-east-1`, as CloudFront requires) | Terraform |
| Create the DNS validation records and **wait until the certificate is issued** | Terraform |
| Attach the domain(s) and certificate to CloudFront (TLS 1.2+, HTTP → HTTPS redirect) | Terraform |
| Create `A` + `AAAA` (IPv4 + IPv6) alias records for every hostname | Terraform |
| Add the domain to the backend's allowed CORS origins | Terraform |
| Print every live URL at the end | deploy script |

**Apex vs subdomain.** An apex domain (`yourclinic.com`) also gets `www.yourclinic.com`; set `include_www = false` in tfvars to skip it. A subdomain (`chat.yourclinic.com`) gets only that hostname, so the clinic's existing website keeps running.

**Redeploys keep the domain.** Running `./scripts/deploy.sh prod` again (for example after editing `clinic_data.txt`) reuses the domain already attached to that environment. To detach it and go back to the CloudFront URL:

```bash
./scripts/deploy.sh prod none
```

**Set it permanently instead (optional).** Put it in `terraform/prod.tfvars`:

```hcl
domain_name      = "yourclinic.com"
hosted_zone_name = ""   # only needed for subdomains when not using the scripts' auto-detection
```

### One-time: put the domain in Route 53

The domain needs a public hosted zone in Route 53 in the same AWS account.

- **Bought through Route 53:** the zone already exists, so nothing to do.
- **Bought elsewhere (Namecheap, GoDaddy, a local .bd registrar…):** create the zone once and point the registrar at it:

  ```bash
  aws route53 create-hosted-zone --name yourclinic.com --caller-reference "$(date +%s)"
  ```

  Copy the 4 `NameServers` from the output into your registrar's **Custom DNS / Nameservers** setting. DNS changes can take from a few minutes up to 48 hours. Check with `nslookup -type=NS yourclinic.com`.

  > Moving nameservers moves **all** DNS for that domain to Route 53. If the domain already has email (MX) or other records, copy them into the new hosted zone first, or use a **subdomain** (`chat.yourclinic.com`) delegated from the existing DNS instead.

If the script can't find a hosted zone, it stops before changing anything and tells you how to create one.

Costs: the ACM certificate is free, and a Route 53 hosted zone is about $0.50 / month.

## 6. Configuration reference

| Variable | Default | Where |
|---|---|---|
| `project_name` | `clinicmate` | `terraform.tfvars` / `prod.tfvars` |
| `environment` | `dev` / `prod` | set by the scripts |
| `openai_model` | `gpt-4o-mini` | tfvars |
| `container_cpu` / `container_memory` | `256` / `512` | tfvars |
| `desired_count` | `1` | tfvars |
| `domain_name` | `""` (CloudFront URL only) | deploy argument or tfvars |
| `hosted_zone_name` | auto-detected | deploy script, or tfvars |
| `include_www` | `true` (apex domains only) | tfvars |
| `openai_api_key` | — (secret) | `backend/.env` → `TF_VAR_openai_api_key` |
| `image_tag` | — | set by the deploy script |

## 7. Troubleshooting

**"Docker doesn't seem to be running"**: start Docker Desktop, wait until it's ready, then re-run the script.

**"OPENAI_API_KEY … looks unset or a placeholder"**: set a real key in `backend/.env`.

**Terraform prompts for `openai_api_key` or `image_tag`**: you ran raw `terraform` instead of the scripts. Use the scripts, or export `TF_VAR_openai_api_key` and pass `-var="image_tag=..."` yourself.

**ECS service never becomes stable**: the container is failing its `/health` check. Check the logs:

```bash
aws logs tail /ecs/clinicmate-dev-api --since 15m
```

**Chat returns an error after deploying**: check the same logs. The usual cause is an invalid or out-of-credit OpenAI key.

**"already exists" errors during apply**: the resource exists in AWS but not in this workspace's state, usually after an interrupted run. Either `terraform import` it or delete it in the console, then re-run the deploy.

**"No public Route 53 hosted zone found"**: the domain (or its parent) has no public hosted zone in this AWS account. See [section 5](#one-time-put-the-domain-in-route-53).

**Custom domain deploy hangs on `aws_acm_certificate_validation`**: AWS can't see the validation records yet, almost always because the registrar's nameservers don't point to the Route 53 zone. Check `nslookup -type=NS yourclinic.com`. Validation finishes within minutes of DNS propagating.

**"CNAMEAlreadyExists" from CloudFront**: that hostname is already attached to another CloudFront distribution, possibly in another AWS account. Remove it there first.

**Frontend shows old content**: the deploy script invalidates CloudFront automatically. Hard-refresh the browser, or wait a minute for the invalidation to finish.

## 8. Cost notes

Each running environment has a small fixed monthly cost, because the backend is always on (no cold starts):

| Resource | Approx. cost |
|---|---|
| Fargate task (0.25 vCPU / 0.5 GB, always on) | ~$9 / month |
| Application Load Balancer | ~$16 / month + data processed |
| ECR, S3, CloudFront, CloudWatch | a few cents at this scale |
| OpenAI usage | billed by OpenAI per token (`gpt-4o-mini` is very low cost) |

That comes to roughly **$25–30 / month per environment**. Destroy `dev`/`test` when you aren't using them, and keep only `prod` running.
