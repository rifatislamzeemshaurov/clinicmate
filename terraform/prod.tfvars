project_name     = "clinicmate"
environment      = "prod"
openai_model     = "gpt-4o-mini"
container_cpu    = 256
container_memory = 512
desired_count    = 1

# Optional custom domain — off by default.
# Flip to true and set root_domain once the domain's hosted zone exists in
# Route 53. See ../DEPLOYMENT.md for the full walkthrough.
use_custom_domain = false
root_domain       = ""

# openai_api_key is intentionally NOT set here — it's a secret, injected via
# TF_VAR_openai_api_key by the deploy/destroy scripts (read from backend/.env).

# image_tag is intentionally NOT set here either — the deploy script builds
# and pushes a fresh image, then passes its tag via -var="image_tag=...".
