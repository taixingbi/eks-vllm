output "file_system_id" {
  description = "EFS file system ID"
  value       = aws_efs_file_system.this.id
}

output "file_system_dns_name" {
  description = "EFS DNS name"
  value       = aws_efs_file_system.this.dns_name
}

output "access_point_id" {
  description = "EFS access point ID for model cache"
  value       = aws_efs_access_point.models.id
}

output "security_group_id" {
  description = "EFS security group ID"
  value       = aws_security_group.efs.id
}
