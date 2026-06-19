output "resource_group_name" {
  description = "Name of the resource group hosting the Windows VM stack."
  value       = azurerm_resource_group.main.name
}

output "vm_name" {
  description = "Windows VM name."
  value       = azurerm_windows_virtual_machine.main.name
}

output "vm_public_ip" {
  description = "Public IP of the VM (null when enable_public_ip is false)."
  value       = var.enable_public_ip ? azurerm_public_ip.main[0].ip_address : null
}
