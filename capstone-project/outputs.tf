output "resource_group_name" {
  description = "Compute Tower Resource Group name."
  value       = azurerm_resource_group.compute.name
}

output "virtual_network_name" {
  description = "Virtual Network name."
  value       = azurerm_virtual_network.compute.name
}

output "subnet_name" {
  description = "Subnet name."
  value       = azurerm_subnet.compute.name
}

output "nsg_name" {
  description = "Network Security Group name."
  value       = azurerm_network_security_group.compute.name
}

output "vm_name" {
  description = "Linux VM name."
  value       = azurerm_linux_virtual_machine.compute.name
}

output "vm_private_ip" {
  description = "Private IP address of the Linux VM."
  value       = azurerm_network_interface.compute.private_ip_address
}

output "bastion_host_name" {
  description = "Azure Bastion host name for secure admin access."
  value       = azurerm_bastion_host.compute.name
}

output "bastion_public_ip" {
  description = "Public IP address of Azure Bastion."
  value       = azurerm_public_ip.bastion.ip_address
}

output "storage_account_name" {
  description = "Compute Tower storage account name."
  value       = azurerm_storage_account.compute.name
}
