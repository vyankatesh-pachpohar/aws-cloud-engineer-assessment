output "sns_topic_arn" {
  value = aws_sns_topic.alerts.arn
}

output "dashboard" {
  value = aws_cloudwatch_dashboard.main.dashboard_name
}
