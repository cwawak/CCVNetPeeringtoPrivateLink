locals {
  base_name = lower(replace(var.project_name, "_", "-"))

  # Confluent may return a DNS domain containing lkc-* prefix.
  # Azure private DNS zone should omit that prefix when present.
  cluster_b_dns_parts = split(".", confluent_network.cluster_b_private_link.dns_domain)
  cluster_b_dns_zone_name = startswith(local.cluster_b_dns_parts[0], "lkc-") ? join(
    ".",
    slice(local.cluster_b_dns_parts, 1, length(local.cluster_b_dns_parts))
  ) : confluent_network.cluster_b_private_link.dns_domain

  # Convert terraform-relative SSH key path to repo-root-relative path for output
  # e.g., "../demo_vm_key" -> "demo_vm_key"
  ssh_key_path_from_root = trimprefix(var.vm_admin_private_key_path, "../")

  # Derive WireGuard tunnel IPs from CIDR
  wireguard_server_ip      = cidrhost(var.wireguard_vpn_cidr, 1)
  wireguard_client_ip      = cidrhost(var.wireguard_vpn_cidr, 2)
  wireguard_prefix_length  = split("/", var.wireguard_vpn_cidr)[1]
  wireguard_server_address = "${cidrhost(var.wireguard_vpn_cidr, 1)}/${split("/", var.wireguard_vpn_cidr)[1]}"
  wireguard_client_address = "${cidrhost(var.wireguard_vpn_cidr, 2)}/32"
}

resource "azurerm_resource_group" "demo" {
  name     = "${local.base_name}-rg"
  location = var.azure_location
  tags     = var.azure_tags
}

# Customer VNet that hosts the demo VM and Cluster B private endpoints.
# ConfluentEnvIDs tag is required by Confluent — without it, the VNet peering
# request is rejected with a 400 error. It tells Confluent which environment
# is authorized to peer with this VNet.
resource "azurerm_virtual_network" "demo" {
  name                = "${local.base_name}-vnet"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name
  address_space       = [var.vnet_address_space]
  tags = merge(var.azure_tags, {
    ConfluentEnvIDs = confluent_environment.demo.id
  })
}

# Subnet for the demo VM. Hosts the WireGuard VPN server that lets the laptop
# reach Private Link and VNet Peering endpoints during deployment and the demo.
resource "azurerm_subnet" "apps" {
  name                 = "${local.base_name}-apps-snet"
  resource_group_name  = azurerm_resource_group.demo.name
  virtual_network_name = azurerm_virtual_network.demo.name
  address_prefixes     = [var.subnet_apps_cidr]
}

# Dedicated subnet for Cluster B's private endpoints. Kept separate from the
# VM subnet so private endpoint policies (which must be disabled) don't affect
# the VM's subnet, and to keep endpoint IPs in a predictable range (10.0.2.x).
resource "azurerm_subnet" "private_endpoint" {
  name                 = "${local.base_name}-pep-snet"
  resource_group_name  = azurerm_resource_group.demo.name
  virtual_network_name = azurerm_virtual_network.demo.name
  address_prefixes     = [var.subnet_private_endpoint_cidr]
}

# NSG applied to the VM subnet. Allows SSH for management and WireGuard (UDP)
# for the VPN tunnel. Restrict vm_source_address_prefix in production.
resource "azurerm_network_security_group" "apps" {
  name                = "${local.base_name}-apps-nsg"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name
  tags                = var.azure_tags

  security_rule {
    name                       = "allow-ssh"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.vm_source_address_prefix
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow-wireguard"
    priority                   = 101
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Udp"
    source_port_range          = "*"
    destination_port_range     = tostring(var.wireguard_listen_port)
    source_address_prefix      = var.vm_source_address_prefix
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "apps" {
  subnet_id                 = azurerm_subnet.apps.id
  network_security_group_id = azurerm_network_security_group.apps.id
}

# Static public IP for the VM. Static allocation is required so the WireGuard
# client config (which embeds this IP as the endpoint) stays valid across VM reboots.
resource "azurerm_public_ip" "vm" {
  name                = "${local.base_name}-vm-pip"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.azure_tags
}

resource "azurerm_network_interface" "vm" {
  name                = "${local.base_name}-vm-nic"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name
  tags                = var.azure_tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.apps.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.vm.id
  }
}

# Ubuntu VM that acts as both the demo client machine and the WireGuard VPN server.
# The VPN is necessary because Cluster A (VNet Peering) and Cluster B (Private Link)
# both resolve to private IPs that are only routable inside the Azure VNet. Without
# the VPN, the laptop can't reach either cluster — and Terraform itself needs that
# connectivity to verify API keys and create the cluster link.
#
# cloud-init bootstraps WireGuard and dnsmasq on first boot. dnsmasq forwards DNS
# queries to Azure's internal resolver (168.63.129.16) so the laptop resolves Cluster
# B hostnames to private endpoint IPs rather than Confluent's internal CIDR (10.1.x.x),
# which is unreachable from outside the VNet.
#
# IMPORTANT — DESTROY ORDER: This VM must be destroyed LAST among resources that need
# VPN connectivity. Confluent resources (cluster link, mirror topic, topics) declare
# depends_on this VM, which reverses destroy order so they're torn down first while
# VPN is still live. Removing those depends_on will cause timeout errors on destroy.
resource "azurerm_linux_virtual_machine" "client_vm" {
  name                = "${local.base_name}-client-vm"
  resource_group_name = azurerm_resource_group.demo.name
  location            = azurerm_resource_group.demo.location
  size                = var.vm_size
  admin_username      = var.vm_admin_username
  network_interface_ids = [
    azurerm_network_interface.vm.id
  ]
  custom_data = base64encode(templatefile("${path.module}/cloud-init-vpn.tftpl", {
    vm_admin_username        = var.vm_admin_username
    wireguard_listen_port    = var.wireguard_listen_port
    wireguard_server_ip      = local.wireguard_server_ip
    wireguard_server_address = local.wireguard_server_address
    wireguard_client_address = local.wireguard_client_address
    wireguard_client_ip      = local.wireguard_client_ip
    wireguard_vpn_cidr       = var.wireguard_vpn_cidr
    vnet_address_space       = var.vnet_address_space
    confluent_peering_cidr   = var.confluent_peering_cidr
  }))

  disable_password_authentication = true

  admin_ssh_key {
    username   = var.vm_admin_username
    public_key = var.vm_admin_public_key
  }

  identity {
    type = "SystemAssigned"
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  tags = var.azure_tags

  # ignore_changes on custom_data prevents Terraform from replacing the VM every
  # time the template is rendered. cloud-init only runs once on first boot, so
  # re-rendering the template has no real effect and shouldn't force a rebuild.
  lifecycle {
    ignore_changes = [custom_data]
  }
}

resource "confluent_environment" "demo" {
  display_name = "${var.project_name}-env"
}

# Confluent-managed network for Cluster A using VNet Peering. Requires a /16 CIDR
# that must not overlap with the customer VNet or other Confluent networks in the
# same region. Confluent uses this CIDR for broker IPs on their side of the peering.
resource "confluent_network" "cluster_a_peering" {
  display_name     = "${var.project_name}-network-a-peering"
  cloud            = "AZURE"
  region           = var.confluent_azure_region
  connection_types = ["PEERING"]
  cidr             = var.confluent_peering_cidr

  environment {
    id = confluent_environment.demo.id
  }
}

# Establishes the VNet peering connection between Confluent's network and the
# customer VNet. This is what makes Cluster A's broker IPs routable from the VNet.
#
# PREREQUISITE — MANUAL ROLE ASSIGNMENT: The "Confluent Cloud" service principal
# must be granted "Network Contributor" on the Azure subscription BEFORE this
# resource is created. If Terraform manages this role assignment, Azure AD propagation
# delay causes confluent_peering to hang indefinitely (12-13+ min with no progress).
# Create the role assignment manually and wait 15-30 min before Phase 3.
# See SETUP.md for the exact az CLI commands.
resource "confluent_peering" "cluster_a_to_vnet" {
  display_name = "${var.project_name}-a-vnet-peering"

  azure {
    tenant          = data.azurerm_client_config.current.tenant_id
    vnet            = azurerm_virtual_network.demo.id
    customer_region = var.azure_vnet_region_short
  }

  environment {
    id = confluent_environment.demo.id
  }

  network {
    id = confluent_network.cluster_a_peering.id
  }

  # Intentionally no depends_on for azurerm_role_assignment.confluent_peering.
  # The role assignment is created manually (outside Terraform) to avoid apply hangs
  # caused by Azure AD role propagation delay.
}

# Source cluster — where data lives before migration. Uses VNet Peering.
# Must wait for peering to be established because brokers are only reachable
# via the peered network, and the cluster won't become healthy without it.
resource "confluent_kafka_cluster" "cluster_a" {
  display_name = "${var.project_name}-cluster-a"
  availability = var.cluster_a_availability
  cloud        = "AZURE"
  region       = var.confluent_azure_region

  dedicated {
    cku = var.cluster_a_cku
  }

  environment {
    id = confluent_environment.demo.id
  }

  network {
    id = confluent_network.cluster_a_peering.id
  }

  depends_on = [
    confluent_peering.cluster_a_to_vnet
  ]
}

# Confluent-managed network for Cluster B using Private Link. Unlike VNet Peering,
# Private Link does not require a customer-supplied CIDR — Confluent assigns one
# internally. The "PRIVATE" DNS resolution mode means brokers only advertise private
# endpoints, so the Azure private DNS zone below is required for name resolution.
#
# PHASE 1 DEPLOYMENT: This network must be created before the VM (Phase 2) because
# its private_link_service_aliases are used as for_each keys for the private endpoints.
# Those aliases are only known after apply, so if this resource and the private endpoints
# are planned in the same pass, Terraform errors with "unknown value in for_each".
resource "confluent_network" "cluster_b_private_link" {
  display_name     = "${var.project_name}-network-b-privatelink"
  cloud            = "AZURE"
  region           = var.confluent_azure_region
  connection_types = ["PRIVATELINK"]

  dns_config {
    resolution = "PRIVATE"
  }

  environment {
    id = confluent_environment.demo.id
  }
}

# Registers this Azure subscription with Confluent so that private endpoint
# connections originating from it are automatically approved. Without this,
# private endpoints would remain in "Pending" state and never connect.
resource "confluent_private_link_access" "cluster_b" {
  display_name = "${var.project_name}-pl-access"

  azure {
    subscription = data.azurerm_subscription.current.subscription_id
  }

  environment {
    id = confluent_environment.demo.id
  }

  network {
    id = confluent_network.cluster_b_private_link.id
  }
}

# Destination cluster — where data lands after migration. Uses Private Link,
# which provides stronger network isolation than VNet Peering (one-way connection,
# no CIDR coordination required, no data exfiltration risk).
resource "confluent_kafka_cluster" "cluster_b" {
  display_name = "${var.project_name}-cluster-b"
  availability = var.cluster_b_availability
  cloud        = "AZURE"
  region       = var.confluent_azure_region

  dedicated {
    cku = var.cluster_b_cku
  }

  environment {
    id = confluent_environment.demo.id
  }

  network {
    id = confluent_network.cluster_b_private_link.id
  }

  depends_on = [
    confluent_private_link_access.cluster_b
  ]
}

# One private endpoint per availability zone exposed by Confluent's Private Link service.
# Each endpoint gets a private IP (10.0.2.x) inside the VNet, making Cluster B
# reachable without any traffic leaving Azure's backbone. The for_each keys are zone
# IDs (e.g. "1", "2", "3") and the values are Confluent's Private Link service aliases.
# These aliases are only known after confluent_network is applied — see Phase 1 note above.
resource "azurerm_private_endpoint" "cluster_b_kafka" {
  for_each = confluent_network.cluster_b_private_link.azure[0].private_link_service_aliases

  name                = "${local.base_name}-${each.key}-pep"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name
  subnet_id           = azurerm_subnet.private_endpoint.id
  tags                = var.azure_tags

  private_service_connection {
    name                              = "${local.base_name}-${each.key}-psc"
    is_manual_connection              = true
    private_connection_resource_alias = each.value
    request_message                   = "Confluent Private Link endpoint for ${each.key}"
  }
}

# Private DNS zone for Cluster B's DNS domain (e.g. abc123.eastus.azure.confluent.cloud).
# Without this zone, the cluster hostname resolves via public DNS to Confluent's
# internal CIDR (10.1.x.x) — which is unreachable from outside the VNet. With this
# zone linked to the VNet, it resolves to the private endpoint IPs (10.0.2.x) instead.
resource "azurerm_private_dns_zone" "cluster_b" {
  name                = local.cluster_b_dns_zone_name
  resource_group_name = azurerm_resource_group.demo.name
  tags                = var.azure_tags
}

# Links the private DNS zone to the VNet so that VMs (and VPN clients via dnsmasq)
# automatically use the zone for resolution. Without this link, the zone exists
# but doesn't affect DNS for anything in the VNet.
resource "azurerm_private_dns_zone_virtual_network_link" "cluster_b" {
  name                  = "${local.base_name}-cluster-b-dns-link"
  resource_group_name   = azurerm_resource_group.demo.name
  private_dns_zone_name = azurerm_private_dns_zone.cluster_b.name
  virtual_network_id    = azurerm_virtual_network.demo.id
}

# Wildcard A record that maps all hostnames in the zone to the private endpoint IPs.
# Confluent uses SNI-based routing on the broker side, so all brokers share the same
# set of private endpoint IPs — the wildcard covers the bootstrap and all broker hostnames.
resource "azurerm_private_dns_a_record" "cluster_b_bootstrap" {
  name                = "*"
  zone_name           = azurerm_private_dns_zone.cluster_b.name
  resource_group_name = azurerm_resource_group.demo.name
  ttl                 = 60
  records = [
    for pe in azurerm_private_endpoint.cluster_b_kafka : pe.private_service_connection[0].private_ip_address
  ]
}

# Per-zone wildcard records (e.g. *.1.<domain>, *.2.<domain>) map zonal broker
# hostnames to each zone's specific endpoint IP. Needed for zone-aware clients
# that connect to individual brokers by zone rather than the bootstrap.
resource "azurerm_private_dns_a_record" "cluster_b_zonal" {
  for_each = azurerm_private_endpoint.cluster_b_kafka

  name                = "*.${each.key}"
  zone_name           = azurerm_private_dns_zone.cluster_b.name
  resource_group_name = azurerm_resource_group.demo.name
  ttl                 = 60
  records             = [each.value.private_service_connection[0].private_ip_address]
}

# Single service account shared by both the producer and consumer. Using one account
# keeps the demo simple — in production you'd typically use separate accounts per
# application with narrower ACLs (e.g. DeveloperRead / DeveloperWrite rather than CloudClusterAdmin).
resource "confluent_service_account" "app" {
  display_name = "${var.project_name}-app-sa"
  description  = "Service account for producer/consumer demo apps."
}

# Grant the service account CloudClusterAdmin on both clusters so it can produce,
# consume, and manage topics without needing separate ACL configuration.
resource "confluent_role_binding" "app_admin_cluster_a" {
  principal   = "User:${confluent_service_account.app.id}"
  role_name   = "CloudClusterAdmin"
  crn_pattern = confluent_kafka_cluster.cluster_a.rbac_crn
}

resource "confluent_role_binding" "app_admin_cluster_b" {
  principal   = "User:${confluent_service_account.app.id}"
  role_name   = "CloudClusterAdmin"
  crn_pattern = confluent_kafka_cluster.cluster_b.rbac_crn
}

# Kafka API key scoped to Cluster A for the producer/consumer scripts.
# The provider verifies this key by calling Cluster A's Kafka REST API, which
# resolves via VNet Peering CIDR — only reachable through the WireGuard VPN.
resource "confluent_api_key" "cluster_a_app_key" {
  display_name = "${var.project_name}-cluster-a-app-key"
  description  = "Kafka API key for demo apps on Cluster A."

  owner {
    id          = confluent_service_account.app.id
    api_version = confluent_service_account.app.api_version
    kind        = confluent_service_account.app.kind
  }

  managed_resource {
    id          = confluent_kafka_cluster.cluster_a.id
    api_version = confluent_kafka_cluster.cluster_a.api_version
    kind        = confluent_kafka_cluster.cluster_a.kind

    environment {
      id = confluent_environment.demo.id
    }
  }

  depends_on = [
    confluent_role_binding.app_admin_cluster_a
  ]
}

# Kafka API key scoped to Cluster B. The provider verifies this key by calling
# Cluster B's Kafka REST API via Private Link (hostname resolves to 10.0.2.x).
# This only works when VPN is connected, dnsmasq is running on the VM, AND the
# corporate DNS proxy is disabled. If any of those conditions aren't met, apply
# will time out here with an i/o timeout to 10.1.x.x (Confluent's internal CIDR).
resource "confluent_api_key" "cluster_b_app_key" {
  display_name = "${var.project_name}-cluster-b-app-key"
  description  = "Kafka API key for demo apps on Cluster B."

  owner {
    id          = confluent_service_account.app.id
    api_version = confluent_service_account.app.api_version
    kind        = confluent_service_account.app.kind
  }

  managed_resource {
    id          = confluent_kafka_cluster.cluster_b.id
    api_version = confluent_kafka_cluster.cluster_b.api_version
    kind        = confluent_kafka_cluster.cluster_b.kind

    environment {
      id = confluent_environment.demo.id
    }
  }

  depends_on = [
    confluent_role_binding.app_admin_cluster_b
  ]
}

# Demo topic on Cluster A — the source of truth before migration. The cluster link
# below will mirror this topic continuously to Cluster B.
resource "confluent_kafka_topic" "orders_cluster_a" {
  kafka_cluster {
    id = confluent_kafka_cluster.cluster_a.id
  }

  topic_name       = var.orders_topic_name
  partitions_count = 1
  rest_endpoint    = confluent_kafka_cluster.cluster_a.rest_endpoint

  credentials {
    key    = confluent_api_key.cluster_a_app_key.id
    secret = confluent_api_key.cluster_a_app_key.secret
  }

  # depends_on VM so topic is destroyed before VM (and VPN) goes down.
  # Cluster A REST API resolves via VNet Peering CIDR, only reachable through VPN.
  depends_on = [azurerm_linux_virtual_machine.client_vm]
}

# Cluster Link from Cluster A (source) to Cluster B (destination), configured in
# DESTINATION/OUTBOUND mode — Cluster B pulls data from Cluster A.
#
# consumer.offset.sync.enable = true — required for the demo's zero-downtime story.
# Continuously syncs consumer group offsets from A to B so that when the consumer
# switches clusters mid-stream, it resumes from exactly the right position with no
# messages lost or replayed.
#
# consumer.offset.group.filters — ALSO required. Without this, offset sync is enabled
# but no consumer groups are actually synced. The wildcard "*" includes all groups.
# The Confluent docs say: "you must enable consumer offset sync AND pass in a group
# filter to identify which groups to sync." Can be updated in-place on an existing link.
#
# consumer.offset.sync.ms = 5000 — sync interval in milliseconds (default is 30000).
# Lowered to 5s so the demo failover works reliably without waiting 30s after stopping
# the consumer on A. Minimum allowed value is 1000ms. NOTE: this setting is read-only
# after creation via the Terraform provider — it can only be set at link creation time.
#
# acl.sync.enable = false because we use RBAC (role bindings) not ACLs, so there's
# nothing to sync.
resource "confluent_cluster_link" "a_to_b" {
  link_name = var.cluster_link_name
  link_mode = "DESTINATION"

  source_kafka_cluster {
    id                 = confluent_kafka_cluster.cluster_a.id
    bootstrap_endpoint = confluent_kafka_cluster.cluster_a.bootstrap_endpoint

    credentials {
      key    = confluent_api_key.cluster_a_app_key.id
      secret = confluent_api_key.cluster_a_app_key.secret
    }
  }

  destination_kafka_cluster {
    id            = confluent_kafka_cluster.cluster_b.id
    rest_endpoint = confluent_kafka_cluster.cluster_b.rest_endpoint

    credentials {
      key    = confluent_api_key.cluster_b_app_key.id
      secret = confluent_api_key.cluster_b_app_key.secret
    }
  }

  config = {
    "consumer.offset.sync.enable"  = "true"
    "consumer.offset.sync.ms"      = "5000"
    "consumer.offset.group.filters" = "{\"groupFilters\": [{\"name\": \"*\", \"patternType\": \"LITERAL\", \"filterType\": \"INCLUDE\"}]}"
    "acl.sync.enable"              = "false"
  }

  # depends_on VM so that during destroy, cluster link (and mirror topic, cluster B API key
  # which depend on this) are destroyed before the VM goes down, keeping VPN alive.
  depends_on = [
    azurerm_private_dns_zone_virtual_network_link.cluster_b,
    azurerm_private_dns_a_record.cluster_b_bootstrap,
    azurerm_private_dns_a_record.cluster_b_zonal,
    azurerm_linux_virtual_machine.client_vm,
    confluent_api_key.cluster_a_app_key,
    confluent_api_key.cluster_b_app_key,
  ]
}

# Mirror topic on Cluster B — a read-only replica of the source topic on Cluster A.
# Read-only by design while mirroring is active, which prevents accidental dual-writes
# during migration. To complete the producer cutover, run promote-to-b.sh which calls
# the Kafka REST API to stop mirroring and make the topic writable.
resource "confluent_kafka_mirror_topic" "orders_on_cluster_b" {
  cluster_link {
    link_name = confluent_cluster_link.a_to_b.link_name
  }

  source_kafka_topic {
    topic_name = var.orders_topic_name
  }

  kafka_cluster {
    id            = confluent_kafka_cluster.cluster_b.id
    rest_endpoint = confluent_kafka_cluster.cluster_b.rest_endpoint

    credentials {
      key    = confluent_api_key.cluster_b_app_key.id
      secret = confluent_api_key.cluster_b_app_key.secret
    }
  }

  depends_on = [
    confluent_kafka_topic.orders_cluster_a
  ]
}

# Pushes Confluent credentials and helper scripts to the VM over SSH after clusters
# are ready. This runs at the end of Phase 3 once both clusters have API keys.
# Triggers re-run when API keys rotate or cluster endpoints change. Keys are hashed
# before storing in triggers so secrets don't appear in plain text in Terraform state.
resource "null_resource" "configure_vm_confluent" {
  triggers = {
    cluster_a_bootstrap  = confluent_kafka_cluster.cluster_a.bootstrap_endpoint
    cluster_b_bootstrap  = confluent_kafka_cluster.cluster_b.bootstrap_endpoint
    cluster_a_api_key_id = confluent_api_key.cluster_a_app_key.id
    cluster_b_api_key_id = confluent_api_key.cluster_b_app_key.id
    cloud_api_key_sha    = sha256(var.confluent_cloud_api_key)
    cloud_api_secret_sha = sha256(var.confluent_cloud_api_secret)
    vm_id                = azurerm_linux_virtual_machine.client_vm.id
  }

  connection {
    type        = "ssh"
    user        = var.vm_admin_username
    private_key = file("${path.module}/../${local.ssh_key_path_from_root}")
    host        = azurerm_public_ip.vm.ip_address
  }

  provisioner "file" {
    source      = "${path.module}/../producer.py"
    destination = "/home/${var.vm_admin_username}/producer.py"
  }

  provisioner "file" {
    source      = "${path.module}/../consumer.py"
    destination = "/home/${var.vm_admin_username}/consumer.py"
  }

  provisioner "file" {
    source      = "${path.module}/../requirements.txt"
    destination = "/home/${var.vm_admin_username}/requirements.txt"
  }

  provisioner "remote-exec" {
    inline = [
      "echo 'Configuring Confluent Cloud credentials on VM...'",

      # Create environment variables file
      "sudo tee /etc/profile.d/confluent-demo.sh > /dev/null << 'ENVEOF'",
      "export CONFLUENT_CLOUD_API_KEY=\"${var.confluent_cloud_api_key}\"",
      "export CONFLUENT_CLOUD_API_SECRET=\"${var.confluent_cloud_api_secret}\"",
      "export DEMO_CLUSTER_A_BOOTSTRAP=\"${confluent_kafka_cluster.cluster_a.bootstrap_endpoint}\"",
      "export DEMO_CLUSTER_A_API_KEY=\"${confluent_api_key.cluster_a_app_key.id}\"",
      "export DEMO_CLUSTER_A_API_SECRET=\"${confluent_api_key.cluster_a_app_key.secret}\"",
      "export DEMO_CLUSTER_B_BOOTSTRAP=\"${confluent_kafka_cluster.cluster_b.bootstrap_endpoint}\"",
      "export DEMO_CLUSTER_B_API_KEY=\"${confluent_api_key.cluster_b_app_key.id}\"",
      "export DEMO_CLUSTER_B_API_SECRET=\"${confluent_api_key.cluster_b_app_key.secret}\"",
      "export DEMO_TOPIC=\"${var.orders_topic_name}\"",
      "export DEMO_GROUP_ID=\"retail-orders-demo-consumer\"",
      "ENVEOF",

      # Create client-a.properties
      "tee ~/client-a.properties > /dev/null << 'CLIENTAEOF'",
      "bootstrap.servers=${confluent_kafka_cluster.cluster_a.bootstrap_endpoint}",
      "security.protocol=SASL_SSL",
      "sasl.mechanism=PLAIN",
      "sasl.username=${confluent_api_key.cluster_a_app_key.id}",
      "sasl.password=${confluent_api_key.cluster_a_app_key.secret}",
      "CLIENTAEOF",

      # Create client-b.properties
      "tee ~/client-b.properties > /dev/null << 'CLIENTBEOF'",
      "bootstrap.servers=${confluent_kafka_cluster.cluster_b.bootstrap_endpoint}",
      "security.protocol=SASL_SSL",
      "sasl.mechanism=PLAIN",
      "sasl.username=${confluent_api_key.cluster_b_app_key.id}",
      "sasl.password=${confluent_api_key.cluster_b_app_key.secret}",
      "CLIENTBEOF",

      # Create use-cluster-a.sh
      "tee ~/use-cluster-a.sh > /dev/null << 'USEASEOF'",
      "#!/usr/bin/env bash",
      "set -x",
      "export KAFKA_BOOTSTRAP_SERVERS=\"${confluent_kafka_cluster.cluster_a.bootstrap_endpoint}\"",
      "export KAFKA_API_KEY=\"${confluent_api_key.cluster_a_app_key.id}\"",
      "export KAFKA_API_SECRET=\"${confluent_api_key.cluster_a_app_key.secret}\"",
      "export KAFKA_TOPIC=\"${var.orders_topic_name}\"",
      "export KAFKA_GROUP_ID=\"retail-orders-demo-consumer\"",
      "cp \"$HOME/client-a.properties\" \"$HOME/client.properties\"",
      "set +x",
      "echo \"Switched demo env to Cluster A.\"",
      "USEASEOF",

      # Create use-cluster-b.sh
      "tee ~/use-cluster-b.sh > /dev/null << 'USEBEOF'",
      "#!/usr/bin/env bash",
      "set -x",
      "export KAFKA_BOOTSTRAP_SERVERS=\"${confluent_kafka_cluster.cluster_b.bootstrap_endpoint}\"",
      "export KAFKA_API_KEY=\"${confluent_api_key.cluster_b_app_key.id}\"",
      "export KAFKA_API_SECRET=\"${confluent_api_key.cluster_b_app_key.secret}\"",
      "export KAFKA_TOPIC=\"${var.orders_topic_name}\"",
      "export KAFKA_GROUP_ID=\"retail-orders-demo-consumer\"",
      "cp \"$HOME/client-b.properties\" \"$HOME/client.properties\"",
      "set +x",
      "echo \"Switched demo env to Cluster B.\"",
      "USEBEOF",

      # Set permissions
      "chmod 600 ~/client-a.properties ~/client-b.properties",
      "chmod 755 ~/use-cluster-a.sh ~/use-cluster-b.sh",

      # Default to cluster A
      "bash ~/use-cluster-a.sh",

      # Create promote-to-b.sh using Confluent CLI (cluster ID baked in at apply time).
      # The script:
      #   1. Checks mirror lag is 0 on all partitions before promoting (producer must be stopped first)
      #   2. Verifies destination consumer group is not active (must stop consumer on B briefly)
      #   3. Runs promote
      #   4. Polls until the topic reaches STOPPED state, then exits
      "tee ~/promote-to-b.sh > /dev/null << 'PROMEOF'",
      "#!/bin/bash",
      "set -e",
      "TOPIC=${var.orders_topic_name}",
      "LINK=${confluent_cluster_link.a_to_b.link_name}",
      "CLUSTER=${confluent_kafka_cluster.cluster_b.id}",
      "ENV=${confluent_environment.demo.id}",
      "GROUP=retail-orders-demo-consumer",
      "# Step 1: Verify mirror lag is 0 on all partitions before promoting.",
      "# If the producer on Cluster A is still running, lag will be non-zero and promote",
      "# will get stuck in PENDING_STOPPED. Stop the producer first.",
      "echo '=== Checking mirror lag (must be 0 before promoting) ==='",
      "LAG_OUTPUT=$(confluent kafka mirror describe $TOPIC --link $LINK --cluster $CLUSTER --environment $ENV -o json 2>&1)",
      "NON_ZERO=$(echo \"$LAG_OUTPUT\" | python3 -c \"import sys,json; data=json.load(sys.stdin); bad=[p for p in data if p.get('partition_mirror_lag',-1) not in (0,-1)]; print(len(bad))\" 2>/dev/null || echo 'err')",
      "if [ \"$NON_ZERO\" != '0' ]; then",
      "  echo 'ERROR: Mirror lag is not 0. Stop the producer on Cluster A first, then retry.'",
      "  confluent kafka mirror describe $TOPIC --link $LINK --cluster $CLUSTER --environment $ENV",
      "  exit 1",
      "fi",
      "echo 'Lag is 0. Proceeding with promote.'",
      "# Step 2: Verify destination consumer group is not active.",
      "# If group is active on Cluster B, promote can stall in PENDING_STOPPED with",
      "# CONSUMER_GROUP_IN_USE_ERROR. Pause the consumer briefly, promote, then restart.",
      "echo '=== Checking destination consumer group state ==='",
      "GROUP_STATE=$(confluent kafka consumer group describe $GROUP --cluster $CLUSTER --environment $ENV -o json 2>/dev/null | python3 -c \"import sys,json; d=json.load(sys.stdin); print(d.get('state','UNKNOWN'))\" 2>/dev/null || echo 'UNKNOWN')",
      "echo \"Consumer group $GROUP state on Cluster B: $GROUP_STATE\"",
      "if [ \"$GROUP_STATE\" = 'STABLE' ] || [ \"$GROUP_STATE\" = 'PREPARING_REBALANCE' ] || [ \"$GROUP_STATE\" = 'COMPLETING_REBALANCE' ]; then",
      "  echo 'ERROR: Consumer group is active on Cluster B. Stop consumer.py on Cluster B, then retry promote.'",
      "  exit 1",
      "fi",
      "# Step 3: Promote the mirror topic.",
      "echo '=== Promoting mirror topic on Cluster B ==='",
      "PROMOTE_OUTPUT=$(confluent kafka mirror promote $TOPIC --link $LINK --cluster $CLUSTER --environment $ENV 2>&1) || { echo \"$PROMOTE_OUTPUT\"; echo 'ERROR: Promote command failed. If topic remains PENDING_STOPPED, check state-transition errors below.'; confluent kafka mirror state-transition-error list $TOPIC --link $LINK --cluster $CLUSTER --environment $ENV || true; exit 1; }",
      "echo \"$PROMOTE_OUTPUT\"",
      "# Step 4: Poll until the topic reaches STOPPED state.",
      "echo '=== Waiting for topic to reach STOPPED state ==='",
      "for i in $(seq 1 120); do",
      "  STATUS=$(confluent kafka mirror describe $TOPIC --link $LINK --cluster $CLUSTER --environment $ENV -o json 2>/dev/null | python3 -c \"import sys,json; data=json.load(sys.stdin); print(data[0].get('mirror_status','UNKNOWN'))\" 2>/dev/null || echo 'UNKNOWN')",
      "  echo \"  [$i/120] Status: $STATUS\"",
      "  if [ \"$STATUS\" = 'STOPPED' ]; then",
      "    echo \"=== Done. $TOPIC is now writable on Cluster B. ===\"",
      "    exit 0",
      "  fi",
      "  sleep 2",
      "done",
      "echo 'ERROR: Topic did not reach STOPPED state after 240s.'",
      "echo 'Checking mirror state-transition errors for a precise cause...'",
      "confluent kafka mirror state-transition-error list $TOPIC --link $LINK --cluster $CLUSTER --environment $ENV || true",
      "echo 'Checking destination consumer group state...'",
      "confluent kafka consumer group describe $GROUP --cluster $CLUSTER --environment $ENV || true",
      "exit 1",
      "PROMEOF",
      "chmod 755 ~/promote-to-b.sh",

      "echo 'Confluent configuration complete!'"
    ]
  }

  depends_on = [
    confluent_api_key.cluster_a_app_key,
    confluent_api_key.cluster_b_app_key,
    azurerm_linux_virtual_machine.client_vm
  ]
}
