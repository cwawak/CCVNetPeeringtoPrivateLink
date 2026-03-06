# Azure prerequisites for Confluent Cloud VNet Peering
# This file creates the necessary permissions for Confluent to establish peering

data "azurerm_client_config" "current" {}

data "azurerm_subscription" "current" {}

# Confluent Cloud's Azure AD Service Principal (fixed App ID for all customers)
data "azuread_service_principal" "confluent" {
  client_id = "f0955e3a-9013-4cf4-a1ea-21587621c9cc"
}

# Custom role allowing Confluent to create and manage VNet peering connections
resource "azurerm_role_definition" "confluent_peering" {
  name        = "${var.project_name}-confluent-peering-role"
  scope       = data.azurerm_subscription.current.id
  description = "Allows Confluent Cloud to create VNet peering connections for this demo"

  permissions {
    actions = [
      "Microsoft.Network/virtualNetworks/read",
      "Microsoft.Network/virtualNetworks/virtualNetworkPeerings/read",
      "Microsoft.Network/virtualNetworks/virtualNetworkPeerings/write",
      "Microsoft.Network/virtualNetworks/virtualNetworkPeerings/delete",
      "Microsoft.Network/virtualNetworks/peer/action"
    ]
    not_actions = []
  }

  assignable_scopes = [
    data.azurerm_subscription.current.id
  ]
}

# Grant the custom role to Confluent's service principal at subscription level
# This allows Confluent to peer with any VNet in this subscription
# NOTE: Intentionally managed manually (outside Terraform).
# Why commented out:
# - Creating this assignment in Terraform can block/hang due to Azure AD propagation delay.
# - When that happens, `confluent_peering` cannot start, and full apply stalls.
#
# Manual command sequence (run once per subscription, then wait 15-30 min):
#   CONFLUENT_APP_ID="f0955e3a-9013-4cf4-a1ea-21587621c9cc"
#   SUBSCRIPTION_ID=$(az account show --query id -o tsv)
#   az ad sp show --id "$CONFLUENT_APP_ID" >/dev/null 2>&1 || az ad sp create --id "$CONFLUENT_APP_ID"
#   CONFLUENT_SP_OBJECT_ID=$(az ad sp show --id "$CONFLUENT_APP_ID" --query id -o tsv)
#   az role assignment create \
#     --assignee-object-id "$CONFLUENT_SP_OBJECT_ID" \
#     --assignee-principal-type ServicePrincipal \
#     --role "Network Contributor" \
#     --scope "/subscriptions/$SUBSCRIPTION_ID"
#
# resource "azurerm_role_assignment" "confluent_peering" {
#   scope                = data.azurerm_subscription.current.id
#   role_definition_name = azurerm_role_definition.confluent_peering.name
#   principal_id         = data.azuread_service_principal.confluent.object_id
#
#   depends_on = [
#     azurerm_role_definition.confluent_peering
#   ]
# }
