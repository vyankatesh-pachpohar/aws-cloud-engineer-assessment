output "alb_arn"                 { value = aws_lb.this.arn }
output "alb_arn_suffix"          { value = aws_lb.this.arn_suffix }         # e.g. app/name/hex
output "alb_dns_name"            { value = aws_lb.this.dns_name }
output "alb_zone_id"             { value = aws_lb.this.zone_id }
output "alb_sg_id"               { value = aws_security_group.alb.id }
output "target_group_arn"        { value = aws_lb_target_group.app.arn }
output "target_group_arn_suffix" { value = aws_lb_target_group.app.arn_suffix } # targetgroup/name/hex
