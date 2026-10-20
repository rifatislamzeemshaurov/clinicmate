#!/bin/bash
set -e

if [ $# -eq 0 ]; then
    echo "Error: Environment parameter is required"
    echo "Usage: $0 <environment>"
    echo "Example: $0 dev"
    echo "Available environments: dev, test, prod"
    exit 1
fi

ENVIRONMENT=$1
PROJECT_NAME=${2:-clinicmate}

echo "Preparing to destroy ${PROJECT_NAME}-${ENVIRONMENT} infrastructure..."

# project root, then into terraform/
cd "$(dirname "$0")/.."

# --- Load OPENAI_API_KEY from backend/.env --------------------------------
if [ -f "backend/.env" ]; then
  OPENAI_KEY=$(grep -m1 '^OPENAI_API_KEY=' backend/.env | cut -d '=' -f2-)
  if [ -n "$OPENAI_KEY" ]; then
    export TF_VAR_openai_api_key="$OPENAI_KEY"
  fi
fi

cd terraform

if ! terraform workspace list | grep -q "$ENVIRONMENT"; then
    echo "Error: Workspace '$ENVIRONMENT' does not exist"
    echo "Available workspaces:"
    terraform workspace list
    exit 1
fi

terraform workspace select "$ENVIRONMENT"

echo "Emptying S3 buckets..."

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

FRONTEND_BUCKET="${PROJECT_NAME}-${ENVIRONMENT}-frontend-${AWS_ACCOUNT_ID}"
MEMORY_BUCKET="${PROJECT_NAME}-${ENVIRONMENT}-memory-${AWS_ACCOUNT_ID}"

if aws s3 ls "s3://$FRONTEND_BUCKET" 2>/dev/null; then
    echo "  Emptying $FRONTEND_BUCKET..."
    aws s3 rm "s3://$FRONTEND_BUCKET" --recursive
else
    echo "  Frontend bucket not found or already empty"
fi

if aws s3 ls "s3://$MEMORY_BUCKET" 2>/dev/null; then
    echo "  Emptying $MEMORY_BUCKET..."
    aws s3 rm "s3://$MEMORY_BUCKET" --recursive
else
    echo "  Memory bucket not found or already empty"
fi

# `image_tag` isn't used by anything `destroy` needs to actually remove
# (the ECR repo has force_delete = true, so leftover images don't block it),
# but the variable is required by the config, so pass a placeholder.
echo "Running terraform destroy..."

if [ "$ENVIRONMENT" = "prod" ] && [ -f "prod.tfvars" ]; then
    terraform destroy -var-file=prod.tfvars -var="project_name=$PROJECT_NAME" -var="environment=$ENVIRONMENT" -var="image_tag=destroy" -auto-approve
else
    terraform destroy -var="project_name=$PROJECT_NAME" -var="environment=$ENVIRONMENT" -var="image_tag=destroy" -auto-approve
fi

echo "Infrastructure for ${ENVIRONMENT} has been destroyed!"
echo ""
echo "To remove the workspace completely, run:"
echo "   terraform workspace select default"
echo "   terraform workspace delete $ENVIRONMENT"
