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
# module "key_valut" {
#   source = "./modules/terraform-azurerm-key-vault"

#   for_each = { for k,v in local.key_valut : k=>v if lookup(v, "enabled", true) }
  
# }