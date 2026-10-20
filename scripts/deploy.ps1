param(
    [string]$Environment = "dev",   # dev | test | prod
    [string]$ProjectName = "clinicmate"
)
$ErrorActionPreference = "Stop"

# PowerShell 5.1 note: $ErrorActionPreference = "Stop" only affects cmdlet
# errors, NOT native-executable failures (uv, terraform, npm, aws, docker all
# count as native here). A failing native command just sets $LASTEXITCODE and
# lets the script keep going unless we check it ourselves - so every native
# call below is followed by an explicit check.
function Assert-LastExitCode {
    param([string]$Step)
    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host "FAILED: $Step (exit code $LASTEXITCODE)" -ForegroundColor Red
        exit $LASTEXITCODE
    }
}

Write-Host "Deploying $ProjectName to $Environment ..." -ForegroundColor Green

# Move to project root (clinicmate/)
Set-Location (Split-Path $PSScriptRoot -Parent)

# --- Pre-flight: Docker Desktop must be running to build the backend image -
Write-Host "Checking Docker is running..." -ForegroundColor Yellow
docker info *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "Docker doesn't seem to be running." -ForegroundColor Red
    Write-Host "Start Docker Desktop, wait until it says 'Docker Desktop is running', then re-run this script." -ForegroundColor Yellow
    exit 1
}

# --- Load OPENAI_API_KEY from backend/.env -------------------------------
# The key is never duplicated into terraform.tfvars. Terraform auto-reads
# any TF_VAR_<name> environment variable as the value for variable <name>,
# so setting TF_VAR_openai_api_key here is all that's needed.
$envFile = "backend\.env"
if (-not (Test-Path $envFile)) {
    Write-Host "backend\.env not found - cannot read OPENAI_API_KEY." -ForegroundColor Red
    exit 1
}
$openaiLine = Get-Content $envFile | Where-Object { $_ -match '^OPENAI_API_KEY=' } | Select-Object -First 1
if (-not $openaiLine) {
    Write-Host "OPENAI_API_KEY is not set in backend\.env." -ForegroundColor Red
    exit 1
}
$openaiKey = ($openaiLine -split '=', 2)[1].Trim()
if ([string]::IsNullOrWhiteSpace($openaiKey) -or $openaiKey -eq "your_openai_api_key_here") {
    Write-Host "OPENAI_API_KEY in backend\.env looks like a placeholder, not a real key." -ForegroundColor Red
    exit 1
}
$env:TF_VAR_openai_api_key = $openaiKey

# --- AWS region (used for ECR login) --------------------------------------
$Region = aws configure get region
if ([string]::IsNullOrWhiteSpace($Region)) { $Region = "ap-south-1" }

# 1. Terraform workspace select + bootstrap the ECR repo only.
#    (The full apply further down needs an image_tag that already exists in
#    ECR, so the repo itself has to exist first - classic bootstrap order.)
Set-Location terraform
terraform init -input=false
Assert-LastExitCode "terraform init"

$workspaces = terraform workspace list
if (-not ($workspaces | Select-String "\b$Environment\b")) {
    terraform workspace new $Environment
    Assert-LastExitCode "terraform workspace new $Environment"
} else {
    terraform workspace select $Environment
    Assert-LastExitCode "terraform workspace select $Environment"
}

Write-Host "Ensuring ECR repository exists..." -ForegroundColor Yellow
# NOTE: -target must be quoted here. Windows PowerShell 5.1 mis-tokenizes an
# unquoted "-target=resource.name" argument to a native executable (it splits
# on the dot), which terraform then rejects as "Too many command line
# arguments" / "Invalid target". Quoting avoids PowerShell's tokenizer
# entirely - terraform.exe receives the flag as a single argument.
terraform apply -target="aws_ecr_repository.backend" `
    -var="project_name=$ProjectName" -var="environment=$Environment" `
    -var="image_tag=bootstrap" -auto-approve
Assert-LastExitCode "terraform apply (ECR bootstrap)"

$EcrUrl = terraform output -raw ecr_repository_url
Assert-LastExitCode "terraform output ecr_repository_url"

# 2. Build + push the backend image
Set-Location ..
$ImageTag = Get-Date -Format "yyyyMMddHHmmss"
Write-Host "Building backend image ($EcrUrl`:$ImageTag)..." -ForegroundColor Yellow

$RegistryHost = ($EcrUrl -replace '/.*$', '')
# NOTE: piping "aws ecr get-login-password" straight into "docker login
# --password-stdin" through PowerShell's own pipeline corrupts the token on
# Windows (login fails with a 400 even though the token itself is valid -
# confirmed by the same token working via -password directly). Routing the
# same pipe through cmd.exe avoids whatever PowerShell's pipeline is doing to
# the bytes, while still keeping the password off the command line/process list.
cmd /c "aws ecr get-login-password --region $Region | docker login --username AWS --password-stdin $RegistryHost"
Assert-LastExitCode "docker login to ECR"

docker build -t "${EcrUrl}:${ImageTag}" -f backend/Dockerfile backend
Assert-LastExitCode "docker build"

docker push "${EcrUrl}:${ImageTag}"
Assert-LastExitCode "docker push"

# 3. Full terraform apply - creates/updates everything, including a new ECS
#    task definition revision pointing at the image we just pushed, which
#    rolls the service forward automatically.
Set-Location terraform
if ($Environment -eq "prod") {
    terraform apply -var-file="prod.tfvars" -var="project_name=$ProjectName" -var="environment=$Environment" -var="image_tag=$ImageTag" -auto-approve
} else {
    terraform apply -var="project_name=$ProjectName" -var="environment=$Environment" -var="image_tag=$ImageTag" -auto-approve
}
Assert-LastExitCode "terraform apply"

$CfUrl          = terraform output -raw cloudfront_url
$FrontendBucket = terraform output -raw s3_frontend_bucket
$ClusterName    = terraform output -raw ecs_cluster_name
$ServiceName    = terraform output -raw ecs_service_name
try { $CustomUrl = terraform output -raw custom_domain_url } catch { $CustomUrl = "" }

# 4. Wait for the new task(s) to pass ALB health checks and go live
Write-Host "Waiting for the ECS service to become stable (can take a few minutes on first deploy)..." -ForegroundColor Yellow
aws ecs wait services-stable --cluster $ClusterName --services $ServiceName --region $Region
Assert-LastExitCode "ECS service did not reach a stable state - check 'aws ecs describe-services' and CloudWatch logs"

# 5. Build + deploy frontend, pointed at the single CloudFront domain
#    (frontend and API share one domain now, so no CORS setup is needed)
Set-Location ..\frontend

Write-Host "Setting API URL for production build..." -ForegroundColor Yellow
"NEXT_PUBLIC_API_URL=$CfUrl" | Out-File .env.production -Encoding utf8

npm install
Assert-LastExitCode "npm install"

npm run build
Assert-LastExitCode "npm run build"

if (-not (Test-Path "out\index.html")) {
    Write-Host "frontend\out\index.html was not created - check next.config.ts has output: 'export'." -ForegroundColor Red
    exit 1
}

aws s3 sync .\out "s3://$FrontendBucket/" --delete
Assert-LastExitCode "aws s3 sync"

Set-Location ..

# 6. Invalidate CloudFront so the new frontend build is served immediately
Write-Host "Invalidating CloudFront cache..." -ForegroundColor Yellow
$CfDomain = $CfUrl -replace '^https://', ''
$DistId = aws cloudfront list-distributions --query "DistributionList.Items[?DomainName=='$CfDomain'].Id | [0]" --output text
if ($DistId -and $DistId -ne "None") {
    aws cloudfront create-invalidation --distribution-id $DistId --paths "/*" *> $null
}

# 7. Final summary
Write-Host ""
Write-Host "Deployment complete!" -ForegroundColor Green
Write-Host "App URL       : $CfUrl" -ForegroundColor Cyan
if ($CustomUrl) {
    Write-Host "Custom domain : $CustomUrl" -ForegroundColor Cyan
}
Write-Host "ECS cluster   : $ClusterName" -ForegroundColor Cyan
Write-Host "ECS service   : $ServiceName" -ForegroundColor Cyan
Write-Host "Image deployed: ${EcrUrl}:${ImageTag}" -ForegroundColor Cyan
