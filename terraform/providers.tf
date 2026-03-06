terraform {
  required_version = ">= 1.5.0"

  required_providers {
    confluent = {
      source  = "confluentinc/confluent"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.61"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

provider "confluent" {
  cloud_api_key    = var.confluent_cloud_api_key
  cloud_api_secret = var.confluent_cloud_api_secret
}

provider "azurerm" {
  features {}

  # Uses credentials from 'az login' - no service principal needed
  # To specify a subscription: az account set --subscription "SUBSCRIPTION_ID"
  # Or set via azure_subscription_id variable
  subscription_id = var.azure_subscription_id
}

provider "azuread" {
  # Uses credentials from 'az login'
}
