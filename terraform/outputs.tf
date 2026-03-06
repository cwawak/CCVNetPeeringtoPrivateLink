output "resource_group_name" {
  description = "Azure resource group for the demo."
  value       = azurerm_resource_group.demo.name
}

output "vm_public_ip" {
  description = "Public IP of demo VM."
  value       = azurerm_public_ip.vm.ip_address
}

output "vm_private_ip" {
  description = "Private IP of demo VM (within Azure VNet)."
  value       = azurerm_network_interface.vm.private_ip_address
}

output "ssh_command" {
  description = "SSH command to connect to the VM (execute from repo root)."
  value       = "ssh -i ${local.ssh_key_path_from_root} ${var.vm_admin_username}@${azurerm_public_ip.vm.ip_address}"
}

output "cluster_a_bootstrap_server" {
  description = "Cluster A bootstrap endpoint."
  value       = confluent_kafka_cluster.cluster_a.bootstrap_endpoint
}

output "cluster_b_bootstrap_server" {
  description = "Cluster B bootstrap endpoint."
  value       = confluent_kafka_cluster.cluster_b.bootstrap_endpoint
}

output "cluster_a_api_key" {
  description = "Kafka API key for Cluster A."
  value       = confluent_api_key.cluster_a_app_key.id
}

output "cluster_a_api_secret" {
  description = "Kafka API secret for Cluster A."
  value       = confluent_api_key.cluster_a_app_key.secret
  sensitive   = true
}

output "cluster_b_api_key" {
  description = "Kafka API key for Cluster B."
  value       = confluent_api_key.cluster_b_app_key.id
}

output "cluster_b_api_secret" {
  description = "Kafka API secret for Cluster B."
  value       = confluent_api_key.cluster_b_app_key.secret
  sensitive   = true
}

output "cluster_link_name" {
  description = "Cluster link name from A to B."
  value       = confluent_cluster_link.a_to_b.link_name
}

output "orders_topic_name" {
  description = "Source/mirror topic used by demo."
  value       = var.orders_topic_name
}
