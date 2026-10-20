variable "project_name" {
  description = "Name prefix for all resources"
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.project_name))
    error_message = "Project name must contain only lowercase letters, numbers, and hyphens."
  }
}

variable "environment" {
  description = "Environment name (dev, test, prod)"
  type        = string
  validation {
    condition     = contains(["dev", "test", "prod"], var.environment)
    error_message = "Environment must be one of: dev, test, prod."
  }
}

variable "openai_api_key" {
  description = "OpenAI API key used by the backend. Pass via TF_VAR_openai_api_key, never commit it."
  type        = string
  sensitive   = true
}

variable "openai_model" {
  description = "OpenAI chat model used for assistant replies and the scope classifier"
  type        = string
  default     = "gpt-4o-mini"
}

variable "image_tag" {
  description = "Docker image tag in ECR that the ECS task definition should run. Set by the deploy script after it pushes a fresh image."
  type        = string
}

variable "container_port" {
  description = "Port the backend container listens on"
  type        = number
  default     = 8000
}

variable "container_cpu" {
  description = "Fargate task CPU units (256 = 0.25 vCPU)"
  type        = number
  default     = 256
}

variable "container_memory" {
  description = "Fargate task memory in MiB"
  type        = number
  default     = 512
}

variable "desired_count" {
  description = "Number of always-on backend tasks to run"
  type        = number
  default     = 1
}

variable "domain_name" {
  description = "Optional custom domain, e.g. \"yourclinic.com\" or \"chat.yourclinic.com\". Leave empty to use the CloudFront default domain."
  type        = string
  default     = ""
  validation {
    condition     = var.domain_name == "" || can(regex("^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?[.])+[a-zA-Z]{2,}$", trimspace(var.domain_name)))
    error_message = "domain_name must be a valid hostname such as yourclinic.com or chat.yourclinic.com (no https://, no trailing slash)."
  }
}

variable "hosted_zone_name" {
  description = "Route 53 public hosted zone that contains domain_name. Defaults to domain_name itself; set it when domain_name is a subdomain (e.g. zone \"yourclinic.com\" for \"chat.yourclinic.com\"). The deploy scripts detect it automatically."
  type        = string
  default     = ""
}

variable "include_www" {
  description = "When domain_name is the zone apex, also serve www.<domain_name>"
  type        = bool
  default     = true
}
