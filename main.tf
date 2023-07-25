#############################################################################
terraform {
  required_providers {
    azuread = {
      source = "hashicorp/azuread"
      version = "2.40.0"
    }

    azurerm = {
      source = "hashicorp/azurerm"
      version = "3.65.0"
    }

    random = {
      source  = "hashicorp/random"
      version = "~>3.0"
    }
  }
}

provider "azuread" {
  # Configuration options
}

provider "azurerm" {
  features {}
}

##############################################################################
# Create Resource Group
module "resource_group" {
  source = "./modules/terraform-azurerm-rg"

  for_each = { for k,v in local.resource_group : k=>v if lookup(v, "enabled", true) }

  location       = each.value.region
  client_name    = lookup(each.value, "client_name" , "")
  environment    = lookup(each.value, "environment" , "")
  stack          = lookup(each.value, "stack" , "")
  custom_rg_name = lookup(each.value, "custom_rg_name" , null)
}

##############################################################################
# Create NSG and NSG Rules
module "network-security-group" {
    source = "./modules/terraform-azurerm-network-security-group"

    for_each = { for k,v in local.network_security_group : k=>v if lookup(v, "enabled", true) }

    resource_group_name        = module.resource_group[each.value.rsg].resource_group_name
    location                   = lookup(each.value , "region", module.resource_group[each.value.rsg].resource_group_location)
    security_group_name        = "nsg-${local.env_prefix_lower}-${each.key}"
    predefined_rules           = lookup(each.value, "predefined_rules" , [])
    custom_rules               = lookup(each.value, "custom_rules" , [])
    tags                       = lookup(each.value, "tags" , {})

    depends_on = [ 
      module.resource_group 
    ]
}

##############################################################################
# Create Vnet、Subnet
resource "azurerm_virtual_network" "this" {
  for_each = { for k,v in local.virtual_network : k=>v if lookup(v, "enabled", true) }

  name                = each.value.name
  resource_group_name = module.resource_group[each.value.rsg].resource_group_name
  location            = lookup(each.value , "region", module.resource_group[each.value.rsg].resource_group_location)
  address_space       = each.value.cidr

  depends_on = [ 
      module.resource_group 
  ]
}

resource "azurerm_subnet" "this" {
  for_each = { for k,v in local.subnets : k=>v if lookup(v, "enabled", true) }

  name                 = each.value.name
  resource_group_name  = module.resource_group[each.value.rsg].resource_group_name
  virtual_network_name = azurerm_virtual_network.this[each.value.vnet_name].name
  address_prefixes     = each.value.cidr

  depends_on = [ 
      module.resource_group,
      azurerm_virtual_network.this
  ]
}

resource "azurerm_subnet_network_security_group_association" "this" {
  for_each = { for k,v in local.subnets : k=>v if lookup(v, "enabled", true) }

  subnet_id                 = azurerm_subnet.this[each.key].id
  network_security_group_id = module.network-security-group[each.value.nsg].network_security_group_id

  depends_on = [ 
      module.resource_group,
      azurerm_subnet.this
  ]
}

##############################################################################
# Bastion
resource "azurerm_public_ip" "this" {
  for_each = { for k,v in local.bastion : k=>v if lookup(v, "enabled", true) }

  name                = "public-ip-${local.env_prefix_lower}-${each.key}"
  resource_group_name = module.resource_group[each.value.rsg].resource_group_name
  location            = lookup(each.value , "region", module.resource_group[each.value.rsg].resource_group_location)
  allocation_method   = lookup(each.value, "public_ip_allocation_method", "Static")
  sku                 = lookup(each.value, "public_ip_sku", "Standard")

  depends_on = [ 
      module.resource_group
  ]
}

resource "azurerm_bastion_host" "this" {
  for_each = { for k,v in local.bastion : k=>v if lookup(v, "enabled", true) }

  name                = "bastion-${local.env_prefix_lower}-${split("_", each.key)[1]}"
  resource_group_name = module.resource_group[each.value.rsg].resource_group_name
  location            = lookup(each.value , "region", module.resource_group[each.value.rsg].resource_group_location)

  ip_configuration {
    name                 = "ifconfig-bastion-${local.env_prefix_lower}-${split("_", each.key)[1]}"
    subnet_id            = azurerm_subnet.this[each.value.subnet_name].id
    public_ip_address_id = azurerm_public_ip.this[each.key].id
  }

  depends_on = [ 
    azurerm_public_ip.this,
    azurerm_subnet.this,
  ]
}

##############################################################################
# Create Key Valut
data "azurerm_client_config" "current" {}
resource "azurerm_key_vault" "this" {
  for_each = { for k,v in local.key_vault : k=>v if lookup(v, "enabled", true) }
  
  name                            = "key-vault-${local.env_prefix_lower}-${split("_", each.key)[1]}"
  resource_group_name             = module.resource_group[each.value.rsg].resource_group_name
  location                        = lookup(each.value , "region", module.resource_group[each.value.rsg].resource_group_location)
  tenant_id                       = data.azurerm_client_config.current.tenant_id
  soft_delete_retention_days      = lookup(each.value, "soft_delete_retention_days", 90)
  purge_protection_enabled        = lookup(each.value, "enable_purge_protection", false)
  sku_name                        = lookup(each.value, "key_vault_sku_pricing_tier", "standard")
  enabled_for_disk_encryption     = lookup(each.value, "enabled_for_disk_encryption", true)
  enabled_for_deployment          = lookup(each.value, "enabled_for_deployment", true)
  enabled_for_template_deployment = lookup(each.value, "enabled_for_template_deployment", true)
  enable_rbac_authorization       = lookup(each.value, "enable_rbac_authorization", true)

  depends_on = [ 
      module.resource_group
  ]
}

resource "azurerm_role_assignment" "keyvaultuser" {
  for_each = { for k,v in local.key_vault : k=>v if lookup(v, "enabled", true) }

  scope                = azurerm_key_vault.this[each.key].id
  role_definition_name = "Key Vault Administrator"
  principal_id         = data.azurerm_client_config.current.object_id

  depends_on = [ 
      azurerm_key_vault.this
  ]
}

# Create Rsa key
resource "azurerm_key_vault_key" "this" {
  for_each = { for k,v in local.key_vault_key : k=>v if lookup(v, "enabled", true) && local.key_vault[v.key_vault].enabled }

  name         = "key-${local.env_prefix_lower}-${each.key}"
  key_vault_id = azurerm_key_vault.this[each.value.key_vault].id
  key_type     = each.value.key_type
  key_size     = each.value.key_size
  key_opts = lookup(each.value, "key_opts", ["decrypt","encrypt","sign","unwrapKey","verify","wrapKey",])

  depends_on = [ 
    azurerm_role_assignment.keyvaultuser
  ]
}

# Create user assigned identity
resource "azurerm_user_assigned_identity" "keyvault" {
  for_each = { for k,v in local.key_vault : k=>v if lookup(v, "enabled", true) && lookup(v, "create_user_assigned_identity", false)}

  location            = lookup(each.value , "region", module.resource_group[each.value.rsg].resource_group_location)
  resource_group_name = module.resource_group[each.value.rsg].resource_group_name
  name                = "identity-${local.env_prefix_lower}-key-vault"

  depends_on = [ 
      module.resource_group
  ]
}

resource "azurerm_role_assignment" "keyvaultresource" {
  for_each = { for k,v in local.key_vault : k=>v if lookup(v, "enabled", true) && lookup(v, "create_user_assigned_identity", false)}

  scope                = azurerm_key_vault.this[each.key].id
  role_definition_name = "Key Vault Contributor"
  principal_id         = azurerm_user_assigned_identity.keyvault[each.key].principal_id
}

# Create disk encryption set
resource "azurerm_disk_encryption_set" "this" {
  for_each = { for k,v in local.disk_encryption_set : k=>v if lookup(v, "enabled", true) }

  name                = "des-${local.env_prefix_lower}-${each.key}"
  location            = lookup(each.value , "region", module.resource_group[each.value.rsg].resource_group_location)
  resource_group_name = module.resource_group[each.value.rsg].resource_group_name
  key_vault_key_id    = azurerm_key_vault_key.this[each.key].id

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.keyvault[each.value.key_vault].id]
  }

  depends_on = [ 
      azurerm_key_vault_key.this,
      azurerm_role_assignment.keyvaultresource
  ]
}