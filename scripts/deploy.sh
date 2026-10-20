#!/bin/bash
set -e

ENVIRONMENT=${1:-dev}          # dev | test | prod
PROJECT_NAME=${2:-clinicmate}

echo "Deploying ${PROJECT_NAME} to ${ENVIRONMENT}..."

# project root
cd "$(dirname "$0")/.."

# --- Pre-flight: Docker must be running to build the backend image --------
echo "Checking Docker is running..."
if ! docker info >/dev/null 2>&1; then
  echo "Docker doesn't seem to be running."
  echo "Start Docker (Docker Desktop / dockerd), wait for it to be ready, then re-run this script."
  exit 1
fi

# --- Load OPENAI_API_KEY from backend/.env --------------------------------
if [ ! -f "backend/.env" ]; then
  echo "backend/.env not found - cannot read OPENAI_API_KEY."
  exit 1
fi
OPENAI_KEY=$(grep -m1 '^OPENAI_API_KEY=' backend/.env | cut -d '=' -f2-)
if [ -z "$OPENAI_KEY" ] || [ "$OPENAI_KEY" = "your_openai_api_key_here" ]; then
  echo "OPENAI_API_KEY in backend/.env looks unset or a placeholder."
  exit 1
fi
export TF_VAR_openai_api_key="$OPENAI_KEY"

# --- AWS region (used for ECR login) --------------------------------------
REGION=$(aws configure get region)
REGION=${REGION:-ap-south-1}

# 1. Terraform workspace select + bootstrap the ECR repo only.
#    (The full apply further down needs an image_tag that already exists in
#    ECR, so the repo itself has to exist first - classic bootstrap order.)
cd terraform
terraform init -input=false

if ! terraform workspace list | grep -q "$ENVIRONMENT"; then
  terraform workspace new "$ENVIRONMENT"
else
  terraform workspace select "$ENVIRONMENT"
fi

echo "Ensuring ECR repository exists..."
terraform apply -target=aws_ecr_repository.backend \
  -var="project_name=$PROJECT_NAME" -var="environment=$ENVIRONMENT" \
  -var="image_tag=bootstrap" -auto-approve

ECR_URL=$(terraform output -raw ecr_repository_url)

# 2. Build + push the backend image
cd ..
IMAGE_TAG=$(date +%Y%m%d%H%M%S)
echo "Building backend image (${ECR_URL}:${IMAGE_TAG})..."

aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "${ECR_URL%%/*}"

docker build -t "${ECR_URL}:${IMAGE_TAG}" -f backend/Dockerfile backend
docker push "${ECR_URL}:${IMAGE_TAG}"

# 3. Full terraform apply - creates/updates everything, including a new ECS
#    task definition revision pointing at the image we just pushed, which
#    rolls the service forward automatically.
cd terraform
if [ "$ENVIRONMENT" = "prod" ]; then
  TF_APPLY_CMD=(terraform apply -var-file=prod.tfvars -var="project_name=$PROJECT_NAME" -var="environment=$ENVIRONMENT" -var="image_tag=$IMAGE_TAG" -auto-approve)
else
  TF_APPLY_CMD=(terraform apply -var="project_name=$PROJECT_NAME" -var="environment=$ENVIRONMENT" -var="image_tag=$IMAGE_TAG" -auto-approve)
fi

echo "Applying Terraform..."
"${TF_APPLY_CMD[@]}"

CF_URL=$(terraform output -raw cloudfront_url)
FRONTEND_BUCKET=$(terraform output -raw s3_frontend_bucket)
CLUSTER_NAME=$(terraform output -raw ecs_cluster_name)
SERVICE_NAME=$(terraform output -raw ecs_service_name)
CUSTOM_URL=$(terraform output -raw custom_domain_url 2>/dev/null || true)

# 4. Wait for the new task(s) to pass ALB health checks and go live
echo "Waiting for the ECS service to become stable (can take a few minutes on first deploy)..."
aws ecs wait services-stable --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME" --region "$REGION"

# 5. Build + deploy frontend, pointed at the single CloudFront domain
#    (frontend and API share one domain now, so no CORS setup is needed)
cd ../frontend

echo "Setting API URL for production build..."
echo "NEXT_PUBLIC_API_URL=$CF_URL" > .env.production

npm install
npm run build

if [ ! -f "out/index.html" ]; then
  echo "frontend/out/index.html was not created - check next.config.ts has output: 'export'."
  exit 1
fi

aws s3 sync ./out "s3://$FRONTEND_BUCKET/" --delete
cd ..

# 6. Invalidate CloudFront so the new frontend build is served immediately
echo "Invalidating CloudFront cache..."
CF_DOMAIN=${CF_URL#https://}
DIST_ID=$(aws cloudfront list-distributions --query "DistributionList.Items[?DomainName=='$CF_DOMAIN'].Id | [0]" --output text)
if [ -n "$DIST_ID" ] && [ "$DIST_ID" != "None" ]; then
  aws cloudfront create-invalidation --distribution-id "$DIST_ID" --paths "/*" >/dev/null
fi

# 7. Final messages
echo ""
echo "Deployment complete!"
echo "App URL        : $CF_URL"
if [ -n "$CUSTOM_URL" ]; then
  echo "Custom domain  : $CUSTOM_URL"
fi
echo "ECS cluster    : $CLUSTER_NAME"
echo "ECS service    : $SERVICE_NAME"
echo "Image deployed : ${ECR_URL}:${IMAGE_TAG}"
