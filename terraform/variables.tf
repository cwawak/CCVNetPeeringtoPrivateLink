variable "confluent_cloud_api_key" {
  type        = string
  description = "Confluent Cloud API key for Terraform provider auth."
  sensitive   = true
}

variable "confluent_cloud_api_secret" {
  type        = string
  description = "Confluent Cloud API secret for Terraform provider auth."
  sensitive   = true
}

variable "azure_subscription_id" {
  type        = string
  description = "Azure subscription ID. If not provided, uses the active subscription from 'az login'."
  default     = null
}

variable "project_name" {
  type        = string
  default     = "cc-vnet-peering-privatelink-demo"
  description = "Prefix used for resource names."
}

variable "azure_tags" {
  type = map(string)
  default = {
    managed_by = "terraform"
    project    = "cc-network-migration-demo"
  }
  description = "Tags applied to all Azure resources (Confluent required tags + project identification)."
}

variable "azure_location" {
  type        = string
  default     = "East US"
  description = "Azure location for infrastructure resources."
}

variable "confluent_azure_region" {
  type        = string
  default     = "eastus"
  description = "Confluent Cloud Azure region for both clusters."
}

variable "azure_vnet_region_short" {
  type        = string
  default     = "eastus"
  description = "Short Azure region string used by confluent_peering.customer_region."
}

variable "vnet_address_space" {
  type        = string
  default     = "10.0.0.0/16"
  description = "CIDR for demo VNet."
}

variable "subnet_apps_cidr" {
  type        = string
  default     = "10.0.1.0/26"
  description = "CIDR for VM subnet."
}

variable "subnet_private_endpoint_cidr" {
  type        = string
  default     = "10.0.2.0/27"
  description = "CIDR for private endpoint subnet."
}

variable "confluent_peering_cidr" {
  type        = string
  default     = "10.50.0.0/16"
  description = "CIDR for Confluent peering network (must not overlap VNet ranges)."
}

variable "cluster_a_cku" {
  type        = number
  default     = 1
  description = "CKUs for source Dedicated cluster A."
}

variable "cluster_b_cku" {
  type        = number
  default     = 1
  description = "CKUs for destination Dedicated cluster B."
}

variable "cluster_a_availability" {
  type        = string
  default     = "SINGLE_ZONE"
  description = "Availability for cluster A (SINGLE_ZONE or MULTI_ZONE)."
}

variable "cluster_b_availability" {
  type        = string
  default     = "SINGLE_ZONE"
  description = "Availability for cluster B (SINGLE_ZONE or MULTI_ZONE)."
}

variable "cluster_link_name" {
  type        = string
  default     = "cluster-a-to-cluster-b"
  description = "Cluster link name from A to B."
}

variable "orders_topic_name" {
  type        = string
  default     = "retail.orders.v1"
  description = "Topic used in producer/consumer demo."
}

variable "vm_admin_username" {
  type        = string
  default     = "azureuser"
  description = "Admin username for Ubuntu VM."
}

variable "vm_admin_public_key" {
  type        = string
  description = "SSH public key content (for example: ssh-rsa AAAA... user@host)."
}

variable "vm_admin_private_key_path" {
  type        = string
  default     = "../demo_vm_key"
  description = "Path to SSH private key file for VM provisioning. Can be: (1) '../filename' for keys in repo root, or (2) 'subdir/filename' for keys in subdirectories of repo root."
}

variable "vm_size" {
  type        = string
  default     = "Standard_B2s"
  description = "Azure VM size."
}

variable "vm_source_address_prefix" {
  type        = string
  default     = "*"
  description = "CIDR/range allowed to SSH to VM. Lock this down for real environments."
}

variable "wireguard_listen_port" {
  type        = number
  default     = 51820
  description = "UDP port for WireGuard VPN server."
}

variable "wireguard_vpn_cidr" {
  type        = string
  default     = "10.200.0.0/24"
  description = "IP range for WireGuard VPN tunnel (should not overlap with VNet or Confluent CIDRs)."
}
