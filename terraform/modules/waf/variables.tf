variable "name" {
  description = "Base name for WAF resources"
  type        = string
}

variable "waf_rate_limit" {
  description = "Rate-based rule limit (requests per 5 minutes per IP)"
  type        = number
  default     = 2000
}

variable "waf_managed_rules_action" {
  description = "Action for AWS managed rule groups: count (observe) or block"
  type        = string
  default     = "count"

  validation {
    condition     = contains(["count", "block"], var.waf_managed_rules_action)
    error_message = "waf_managed_rules_action must be count or block."
  }
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "log_retention_in_days" {
  description = "CloudWatch log retention for WAF logs"
  type        = number
  default     = 30
}
