terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.117"
    }
  }
}

provider "azurerm" {
  features {}
}

locals {
  name_prefix = lower(replace("${var.project}-${var.environment}-${var.vm_name}", "_", "-"))

  common_tags = {
    environment = var.environment
    project     = var.project
    owner       = var.owner
  }
}

# Core Infrastructure
resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location
  tags     = local.common_tags
}

resource "azurerm_virtual_network" "main" {
  name                = "${local.name_prefix}-vnet"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = [var.vnet_cidr]
  tags                = local.common_tags
}

resource "azurerm_subnet" "main" {
  name                 = "${local.name_prefix}-subnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.subnet_cidr]
}

# Public IP is enabled by default and can be disabled for private-only deployments.
resource "azurerm_public_ip" "main" {
  count               = var.enable_public_ip ? 1 : 0
  name                = "${local.name_prefix}-pip"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.common_tags
}

# Security
resource "azurerm_network_security_group" "main" {
  name                = "${local.name_prefix}-nsg"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.common_tags
}

resource "azurerm_network_security_rule" "allow_rdp" {
  name                        = "allow-rdp-restricted"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "3389"
  source_address_prefix       = var.allowed_rdp_cidr
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.main.name
  network_security_group_name = azurerm_network_security_group.main.name
}

# Associate NSG with subnet to enforce policy for all NICs in subnet.
resource "azurerm_subnet_network_security_group_association" "main" {
  subnet_id                 = azurerm_subnet.main.id
  network_security_group_id = azurerm_network_security_group.main.id
}

resource "azurerm_network_interface" "main" {
  name                = "${local.name_prefix}-nic"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.common_tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.main.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = var.enable_public_ip ? azurerm_public_ip.main[0].id : null
  }
}

# Windows VM
resource "azurerm_windows_virtual_machine" "main" {
  name                     = var.vm_name
  computer_name            = var.vm_name
  resource_group_name      = azurerm_resource_group.main.name
  location                 = azurerm_resource_group.main.location
  size                     = var.vm_size
  admin_username           = var.admin_username
  admin_password           = var.admin_password
  provision_vm_agent       = var.enable_vm_agent
  enable_automatic_updates = true
  patch_mode               = "AutomaticByPlatform"

  network_interface_ids = [azurerm_network_interface.main.id]

  os_disk {
    name                 = "${local.name_prefix}-osdisk"
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2022-datacenter"
    version   = "latest"
  }

  # Uses managed boot diagnostics storage managed by Azure.
  boot_diagnostics {}

  zone = var.availability_zone != "" ? var.availability_zone : null

  tags = local.common_tags

  depends_on = [azurerm_subnet_network_security_group_association.main]
}
