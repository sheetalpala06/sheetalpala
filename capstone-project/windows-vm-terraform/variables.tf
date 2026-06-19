variable "location" {
  description = "Azure region for all resources."
  type        = string
  default     = "eastus"
}

variable "resource_group_name" {
  description = "Name of the Azure resource group."
  type        = string
}

variable "vm_name" {
  description = "Name of the Windows VM."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9-]{1,15}$", var.vm_name))
    error_message = "vm_name must be 1-15 characters and contain only letters, numbers, and hyphens."
  }
}

variable "admin_username" {
  description = "Administrator username for the Windows VM."
  type        = string
  default     = "azureadmin"

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9]{2,19}$", var.admin_username))
    error_message = "admin_username must be 3-20 alphanumeric characters and start with a letter."
  }
}

variable "admin_password" {
  description = "Administrator password for the Windows VM."
  type        = string
  sensitive   = true

  validation {
    condition = (
      length(var.admin_password) >= 12 &&
      can(regex("[A-Z]", var.admin_password)) &&
      can(regex("[a-z]", var.admin_password)) &&
      can(regex("[0-9]", var.admin_password)) &&
      can(regex("[^A-Za-z0-9]", var.admin_password))
    )
    error_message = "admin_password must be at least 12 characters and include uppercase, lowercase, number, and special character."
  }
}

variable "vm_size" {
  description = "Azure VM SKU size."
  type        = string
  default     = "Standard_B2s"
}

variable "allowed_rdp_cidr" {
  description = "Restricted CIDR allowed to reach RDP (TCP/3389), for example 203.0.113.10/32."
  type        = string

  validation {
    condition     = can(cidrhost(var.allowed_rdp_cidr, 0))
    error_message = "allowed_rdp_cidr must be a valid CIDR block."
  }

  validation {
    condition     = var.allowed_rdp_cidr != "0.0.0.0/0" && var.allowed_rdp_cidr != "*"
    error_message = "allowed_rdp_cidr cannot be open to the world. Use a restricted source CIDR."
  }
}

variable "environment" {
  description = "Environment tag value (for example: dev, test, prod)."
  type        = string
  default     = "dev"
}

variable "project" {
  description = "Project tag value."
  type        = string
  default     = "iac-windows-vm"
}

variable "owner" {
  description = "Owner tag value."
  type        = string
  default     = "cloud-team"
}

variable "vnet_cidr" {
  description = "CIDR block for VNet."
  type        = string
  default     = "10.40.0.0/16"

  validation {
    condition     = can(cidrhost(var.vnet_cidr, 0))
    error_message = "vnet_cidr must be a valid CIDR block."
  }
}

variable "subnet_cidr" {
  description = "CIDR block for subnet."
  type        = string
  default     = "10.40.1.0/24"

  validation {
    condition     = can(cidrhost(var.subnet_cidr, 0))
    error_message = "subnet_cidr must be a valid CIDR block."
  }
}

variable "enable_public_ip" {
  description = "Whether to deploy a public IP and attach it to the VM NIC."
  type        = bool
  default     = true
}

variable "availability_zone" {
  description = "Optional availability zone for the VM (1, 2, 3). Leave empty to disable zonal placement."
  type        = string
  default     = ""

  validation {
    condition     = var.availability_zone == "" || contains(["1", "2", "3"], var.availability_zone)
    error_message = "availability_zone must be empty or one of: 1, 2, 3."
  }
}

variable "enable_vm_agent" {
  description = "Enable Azure VM agent on the Windows VM."
  type        = bool
  default     = true
}
