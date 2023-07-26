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
# Generate random text for a unique storage account name
resource "random_id" "random_id" {
  keepers = {
    # Generate a new ID only when a new resource group is defined
    resource_group = local.resource_group.rg_1.custom_rg_name
  }

  byte_length = 8

  depends_on = [ 
      module.resource_group 
    ]
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

# assign role for user
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

# Create disk encryption set
resource "azurerm_disk_encryption_set" "this" {
  for_each = { for k,v in local.disk_encryption_set : k=>v if lookup(v, "enabled", true) && local.key_vault.kv_1.enabled}

  name                = "des-${local.env_prefix_lower}-${each.key}"
  location            = lookup(each.value , "region", module.resource_group[each.value.rsg].resource_group_location)
  resource_group_name = module.resource_group[each.value.rsg].resource_group_name
  key_vault_key_id    = azurerm_key_vault_key.this[each.key].id

  identity {
    type         = "SystemAssigned"
  }

  depends_on = [ 
      azurerm_key_vault_key.this
  ]
}

resource "azurerm_role_assignment" "disk_encryption_set" {
  for_each = { for k,v in local.disk_encryption_set : k=>v if lookup(v, "enabled", true) && local.key_vault.kv_1.enabled}

  scope                = azurerm_key_vault.this[each.value.key_vault].id
  role_definition_name = "Key Vault Crypto Service Encryption User"
  principal_id         = azurerm_disk_encryption_set.this[each.key].identity.0.principal_id
}

##############################################################################
# Create data disk
resource "azurerm_managed_disk" "this" {
  for_each = { for k,v in local.data_disk : k=>v if lookup(v, "enabled", true) }

  name                    = "disk-${local.env_prefix_lower}-${each.key}"
  location                = lookup(each.value , "region", module.resource_group[each.value.rsg].resource_group_location)
  resource_group_name     = module.resource_group[each.value.rsg].resource_group_name
  storage_account_type    = each.value.storage_account_type
  create_option           = each.value.create_option
  disk_size_gb            = each.value.disk_size_gb
  disk_encryption_set_id  = azurerm_disk_encryption_set.this[each.value.disk_encryption_set].id

  tags = lookup(each.value, "tags" ,{})

  depends_on = [ 
      module.resource_group,
      azurerm_key_vault_key.this
  ]
}

# Create storage account for boot diagnostics
resource "azurerm_storage_account" "diagnostic" {
  for_each = { for k,v in local.storage_account_diagnostic : k=>v if lookup(v, "enabled", true) }

  name                     = "${each.value.name}${random_id.random_id.hex}"
  location                 = lookup(each.value , "region", module.resource_group[each.value.rsg].resource_group_location)
  resource_group_name      = module.resource_group[each.value.rsg].resource_group_name
  account_tier             = each.value.account_tire
  account_replication_type = each.value.account_replication_type

  depends_on = [ 
      module.resource_group
  ]
}


# Create network interface
resource "azurerm_network_interface" "this" {
  for_each = { for k,v in local.virtual_machine : k=>v if lookup(v, "enabled", true) }

  name                = "nic-${local.env_prefix_lower}-${each.key}"
  location            = lookup(each.value , "region", module.resource_group[each.value.rsg].resource_group_location)
  resource_group_name = module.resource_group[each.value.rsg].resource_group_name

  ip_configuration {
    name                          = "nic-${local.env_prefix_lower}-${each.key}-configuration"
    subnet_id                     = azurerm_subnet.this[each.value.subnet_name].id
    private_ip_address_allocation = each.value.private_ip_address_allocation
    public_ip_address_id          = try(azurerm_public_ip.this[each.value.public_ip_name].id, null)
    private_ip_address            = each.value.private_ip_address
  }

  depends_on = [ 
      module.resource_group,
      azurerm_subnet.this,
      azurerm_key_vault_key.this,
      azurerm_managed_disk.this
  ]
}

# Create virtual machine
resource "azurerm_windows_virtual_machine" "this" {
  for_each = { for k,v in local.virtual_machine : k=>v if lookup(v, "enabled", true) }

  name                  = "vm-${local.env_prefix_lower}-${each.key}"
  admin_username        = each.value.admin_username
  admin_password        = each.value.admin_password
  location              = lookup(each.value , "region", module.resource_group[each.value.rsg].resource_group_location)
  resource_group_name   = module.resource_group[each.value.rsg].resource_group_name
  network_interface_ids = [azurerm_network_interface.this[each.key].id]
  size                  = each.value.vm_size

  os_disk {
    name                    = "disk-${local.env_prefix_lower}-${each.key}-os"
    caching                 = each.value.os_disk_cacging
    storage_account_type    = each.value.os_disk_sa_type
    disk_encryption_set_id  = azurerm_disk_encryption_set.this[each.value.disk_encryption_set].id
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2022-datacenter-azure-edition"
    version   = "latest"
  }

  boot_diagnostics {
    storage_account_uri = azurerm_storage_account.diagnostic["boot_diagnostic"].primary_blob_endpoint
  }

  identity {
    type         = "SystemAssigned"
  }

  depends_on = [ 
    azurerm_managed_disk.this,
    azurerm_windows_virtual_machine.this
  ]
}


resource "azurerm_virtual_machine_data_disk_attachment" "this" {
  for_each = { for k,v in local.virtual_machine : k=>v if lookup(v, "attch_data_disk") && lookup(v, "enabled", true)}

  managed_disk_id    = azurerm_managed_disk.this[each.value.data_disk_name].id
  virtual_machine_id = azurerm_windows_virtual_machine.this[each.key].id
  lun                = each.value.data_disk_lun
  caching            = each.value.data_disk_caching

  depends_on = [ 
    module.resource_group,
    azurerm_network_interface.this
  ]

}


resource "azurerm_virtual_machine_extension" "windows_monitor" {
 for_each = { for k,v in local.virtual_machine : k=>v if lookup(v, "enabled", true) && lookup(v, "iswindows") }

 name                       = "vme-${local.env_prefix_lower}-${each.key}"
 virtual_machine_id         = azurerm_windows_virtual_machine.this[each.key].id
 publisher                  = "Microsoft.Azure.Monitor"
 type                       = "AzureMonitorWindowsAgent"
 type_handler_version       = "1.17"
 auto_upgrade_minor_version = "true"
 
 tags = lookup(each.value, "tags" , {})

}