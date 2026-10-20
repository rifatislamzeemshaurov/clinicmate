output "cloudfront_url" {
  description = "URL of the CloudFront distribution (frontend + API, single domain)"
  value       = "https://${aws_cloudfront_distribution.main.domain_name}"
}

output "s3_frontend_bucket" {
  description = "Name of the S3 bucket for frontend"
  value       = aws_s3_bucket.frontend.id
}

output "s3_memory_bucket" {
  description = "Name of the S3 bucket for memory storage"
  value       = aws_s3_bucket.memory.id
}

output "ecr_repository_url" {
  description = "ECR repository URL the deploy script pushes the backend image to"
  value       = aws_ecr_repository.backend.repository_url
}

output "ecs_cluster_name" {
  description = "Name of the ECS cluster"
  value       = aws_ecs_cluster.main.name
}

output "ecs_service_name" {
  description = "Name of the ECS service running the backend"
  value       = aws_ecs_service.api.name
}

output "alb_dns_name" {
  description = "ALB DNS name (internal detail — visit the CloudFront URL instead, not this directly)"
  value       = aws_lb.main.dns_name
}

output "custom_domain_url" {
  description = "Primary custom-domain URL (empty when no custom domain is configured)"
  value       = local.use_custom_domain ? "https://${local.domain_name}" : ""
}

output "custom_domain_hostnames" {
  description = "Every hostname served by CloudFront for the custom domain"
  value       = local.aliases
}
