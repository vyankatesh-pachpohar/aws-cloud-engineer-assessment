output "alb_dns_name" {
  value       = module.alb.alb_dns_name
  description = "Public URL of the API"
}

output "ecr_repository_url" {
  value = module.ecr.repository_url
}

output "ecs_cluster" {
  value = module.ecs.cluster_name
}

output "ecs_service" {
  value = module.ecs.service_name
}

output "rds_endpoint" {
  value     = module.rds.endpoint
  sensitive = true
}

output "db_secret_arn" {
  value = module.secrets.db_secret_arn
}

output "github_deploy_role" {
  value = module.github_oidc.role_arn
}

output "cloudwatch_dashboard" {
  value = module.monitoring.dashboard
}

output "sns_alert_topic" {
  value = module.monitoring.sns_topic_arn
}
