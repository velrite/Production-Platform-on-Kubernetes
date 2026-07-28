variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Short name used as a prefix for all resource names"
  type        = string
  default     = "platform"
}

variable "environment" {
  description = "Which environment this Terraform run targets"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "vpc_cidr" {
  description = "IP address range for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}
