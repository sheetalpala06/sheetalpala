terraform {
  required_version = ">= 1.5.0"

  backend "azurerm" {
    resource_group_name  = "finbridge-tfstate-rg"
    storage_account_name = "finbridgetfstate"
    container_name       = "tfstate"
    key                  = "compute/dev/terraform.tfstate"
  }

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.116"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

locals {
  prefix = "finbridge-${var.environment}"

  names = {
    rg          = "${local.prefix}-rg"
    vnet        = "${local.prefix}-vnet"
    snet        = "${local.prefix}-subnet"
    bastion_pip = "${local.prefix}-bastion-pip"
    bastion     = "${local.prefix}-bastion"
    nsg         = "${local.prefix}-nsg"
    nic         = "${local.prefix}-nic"
    vm          = "${local.prefix}-vm"
  }

  # Storage account names must be 3-24 lowercase alphanumeric chars with no hyphens.
  storage_account_name = substr(replace(lower("${local.prefix}-st"), "-", ""), 0, 24)
}

resource "azurerm_resource_group" "compute" {
  name     = local.names.rg
  location = var.location
  tags     = var.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_virtual_network" "compute" {
  name                = local.names.vnet
  location            = azurerm_resource_group.compute.location
  resource_group_name = azurerm_resource_group.compute.name
  address_space       = [var.vnet_cidr]
  tags                = var.tags
}

resource "azurerm_subnet" "compute" {
  name                 = local.names.snet
  resource_group_name  = azurerm_resource_group.compute.name
  virtual_network_name = azurerm_virtual_network.compute.name
  address_prefixes     = [var.subnet_cidr]
}

resource "azurerm_subnet" "bastion" {
  name                 = "AzureBastionSubnet"
  resource_group_name  = azurerm_resource_group.compute.name
  virtual_network_name = azurerm_virtual_network.compute.name
  address_prefixes     = [var.bastion_subnet_cidr]
}

resource "azurerm_network_security_group" "compute" {
  name                = local.names.nsg
  location            = azurerm_resource_group.compute.location
  resource_group_name = azurerm_resource_group.compute.name
  tags                = var.tags
}

resource "azurerm_network_security_rule" "allow_ssh" {
  name                        = "allow-ssh-from-bastion-subnet"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefix       = var.bastion_subnet_cidr
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.compute.name
  network_security_group_name = azurerm_network_security_group.compute.name
}

resource "azurerm_subnet_network_security_group_association" "compute" {
  subnet_id                 = azurerm_subnet.compute.id
  network_security_group_id = azurerm_network_security_group.compute.id
}

resource "azurerm_public_ip" "bastion" {
  name                = local.names.bastion_pip
  location            = azurerm_resource_group.compute.location
  resource_group_name = azurerm_resource_group.compute.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_bastion_host" "compute" {
  name                = local.names.bastion
  location            = azurerm_resource_group.compute.location
  resource_group_name = azurerm_resource_group.compute.name
  tags                = var.tags

  ip_configuration {
    name                 = "${local.names.bastion}-ipcfg"
    subnet_id            = azurerm_subnet.bastion.id
    public_ip_address_id = azurerm_public_ip.bastion.id
  }
}

resource "azurerm_network_interface" "compute" {
  name                = local.names.nic
  location            = azurerm_resource_group.compute.location
  resource_group_name = azurerm_resource_group.compute.name
  tags                = var.tags

  ip_configuration {
    name                          = "${local.names.nic}-ipcfg"
    subnet_id                     = azurerm_subnet.compute.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_linux_virtual_machine" "compute" {
  name                            = local.names.vm
  resource_group_name             = azurerm_resource_group.compute.name
  location                        = azurerm_resource_group.compute.location
  size                            = var.vm_size
  admin_username                  = var.admin_username
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.compute.id]
  tags                            = var.tags

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.admin_ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    name                 = "${local.prefix}-osdisk"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }
}

resource "azurerm_storage_account" "compute" {
  name                            = local.storage_account_name
  resource_group_name             = azurerm_resource_group.compute.name
  location                        = azurerm_resource_group.compute.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = true
  tags                            = var.tags

  lifecycle {
    prevent_destroy = true
  }
}
