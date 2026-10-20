project_name      = "clinicmate"
environment       = "dev"
openai_model      = "gpt-4o-mini"
container_cpu     = 256
container_memory  = 512
desired_count     = 1
use_custom_domain = false
root_domain       = ""

# openai_api_key is intentionally NOT set here — it's a secret.
# The deploy/destroy scripts read it from backend/.env and pass it via the
# TF_VAR_openai_api_key environment variable automatically.

# image_tag is intentionally NOT set here either — the deploy script builds
# and pushes a fresh image, then passes its tag via -var="image_tag=...".
