project_name     = "clinicmate"
environment      = "prod"
openai_model     = "gpt-4o-mini"
container_cpu    = 256
container_memory = 512
desired_count    = 1

# Optional custom domain — leave empty to use the CloudFront URL.
#   domain_name = "yourclinic.com"        -> yourclinic.com + www.yourclinic.com
#   domain_name = "chat.yourclinic.com"   -> chat.yourclinic.com
# The domain's hosted zone must exist in Route 53 (see ../DEPLOYMENT.md).
# Or pass it at deploy time instead: ./scripts/deploy.sh prod yourclinic.com
domain_name = ""
include_www = true

# openai_api_key is intentionally NOT set here — it's a secret, injected via
# TF_VAR_openai_api_key by the deploy/destroy scripts (read from backend/.env).

# image_tag is intentionally NOT set here either — the deploy script builds
# and pushes a fresh image, then passes its tag via -var="image_tag=...".
