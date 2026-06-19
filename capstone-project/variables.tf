variable "subscription_id" {
  description = "Azure subscription ID where resources will be deployed."
  type        = string
}

variable "location" {
  description = "Azure region for deployment."
  type        = string
  default     = "eastus"
}

variable "environment" {
  description = "Deployment environment used in naming convention finbridge-{env}-{resource}."
  type        = string
  default     = "dev"

  validation {
    condition     = can(regex("^[a-z0-9-]{2,12}$", var.environment))
    error_message = "environment must be 2-12 chars and contain only lowercase letters, numbers, and hyphens."
  }
}

variable "admin_username" {
  description = "Admin username for the Linux VM."
  type        = string
  default     = "finbridgeadmin"

  validation {
    condition     = can(regex("^[a-z_][a-z0-9_-]{2,31}$", var.admin_username))
    error_message = "admin_username must be a valid Linux username (3-32 chars)."
  }
}

variable "admin_ssh_public_key" {
  description = "SSH public key content used for VM access (no password auth)."
  type        = string

  validation {
    condition = (
      startswith(trimspace(var.admin_ssh_public_key), "ssh-rsa ") ||
      startswith(trimspace(var.admin_ssh_public_key), "ssh-ed25519 ") ||
      startswith(trimspace(var.admin_ssh_public_key), "ecdsa-sha2-nistp256 ") ||
      startswith(trimspace(var.admin_ssh_public_key), "ecdsa-sha2-nistp384 ") ||
      startswith(trimspace(var.admin_ssh_public_key), "ecdsa-sha2-nistp521 ")
    )
    error_message = "admin_ssh_public_key must be a valid SSH public key string."
  }
}

variable "admin_allowed_cidr" {
  description = "Trusted CIDR allowed to access SSH (example: 203.0.113.10/32)."
  type        = string

  validation {
    condition     = can(cidrhost(var.admin_allowed_cidr, 0))
    error_message = "admin_allowed_cidr must be a valid CIDR block."
  }

  validation {
    condition     = var.admin_allowed_cidr != "0.0.0.0/0" && var.admin_allowed_cidr != "*"
    error_message = "admin_allowed_cidr cannot be open to the world. Use a specific trusted range."
  }
}

variable "vnet_cidr" {
  description = "CIDR block for Virtual Network."
  type        = string
  default     = "10.30.0.0/16"

  validation {
    condition     = can(cidrhost(var.vnet_cidr, 0))
    error_message = "vnet_cidr must be a valid CIDR block."
  }
}

variable "subnet_cidr" {
  description = "CIDR block for subnet. Must be within vnet_cidr."
  type        = string
  default     = "10.30.1.0/24"

  validation {
    condition     = can(cidrhost(var.subnet_cidr, 0))
    error_message = "subnet_cidr must be a valid CIDR block."
  }
}

variable "bastion_subnet_cidr" {
  description = "CIDR block for Azure Bastion subnet (AzureBastionSubnet)."
  type        = string
  default     = "10.30.2.0/26"

  validation {
    condition     = can(cidrhost(var.bastion_subnet_cidr, 0))
    error_message = "bastion_subnet_cidr must be a valid CIDR block."
  }
}

variable "vm_size" {
  description = "Azure VM SKU size."
  type        = string
  default     = "Standard_B2s"
}

variable "tags" {
  description = "Common tags for all resources."
  type        = map(string)
  default = {
    environment = "dev"
    project     = "finbridge"
    tower       = "compute"
  }
}
