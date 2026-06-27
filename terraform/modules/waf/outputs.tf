output "web_acl_arn" {
  description = "Regional WAF Web ACL ARN for ALB association"
  value       = aws_wafv2_web_acl.this.arn
}

output "web_acl_id" {
  description = "Regional WAF Web ACL ID"
  value       = aws_wafv2_web_acl.this.id
}
