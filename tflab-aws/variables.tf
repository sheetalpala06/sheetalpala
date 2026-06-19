variable "participant_name" {
  description = "Participant name (lowercase, no spaces)"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "admin_password" {
  description = "Admin password used for Linux sudo user and Windows Administrator"
  type        = string
  sensitive   = true
}

variable "linux_instance_type" {
  description = "Instance type for Linux app/db instances"
  type        = string
  default     = "t3.large"
}

variable "windows_instance_type" {
  description = "Instance type for Windows instance"
  type        = string
  default     = "t3.medium"
}

variable "eice_allowed_cidrs" {
  description = "CIDRs allowed to connect to EC2 Instance Connect Endpoint"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
