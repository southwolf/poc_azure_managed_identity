terraform {
  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
      version = "4.24.0"
    }
  }
}

provider "azurerm" {
  features {}
}

resource "azurerm_resource_group" "rg" {
  name     = "poc-managed-identity"
  location = "East Asia"
}

resource "azurerm_virtual_network" "vnet" {
  name                = "poc-vnet"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"]
}

resource "azurerm_subnet" "aks_subnet" {
  name                 = "aks-subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_subnet" "pgsql_subnet" {
  name                 = "pgsql-subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.101.0/24"]
  service_endpoints    = ["Microsoft.Sql"]
  delegation {
    name = "fs"
    service_delegation {
      name = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action",
      ]
    }
  }
  private_endpoint_network_policies  = Enabled
}

resource "azurerm_private_dns_zone" "dns_zone" {
  name                = "poc-managed-idendity.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "dns_link" {
  name                  = "poc-managed-identity.com"
  private_dns_zone_name = azurerm_private_dns_zone.dns_zone.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
  resource_group_name   = azurerm_resource_group.rg.name
  depends_on            = [azurerm_subnet.pgsql_subnet]
}

resource "azurerm_postgresql_flexible_server" "pgsql" {
  name                          = "poc-managed-identity-pgsql"
  resource_group_name           = azurerm_resource_group.rg.name
  location                      = azurerm_resource_group.rg.location
  version                       = "14"
  delegated_subnet_id           = azurerm_subnet.pgsql_subnet.id
  private_dns_zone_id           = azurerm_private_dns_zone.dns_zone.id
  public_network_access_enabled = false
  administrator_login           = "psqladmin"
  administrator_password        = "Secr3tPassw0rd!"
  zone                          = "1"

  storage_mb   = 32768
  storage_tier = "P4"

  sku_name   = "B_Standard_B1ms"
  depends_on = [azurerm_private_dns_zone_virtual_network_link.dns_link]
}

resource "azurerm_private_endpoint" "pgsql_private_endpoint" {
  name                = "pgsql-private-endpoint"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  subnet_id           = azurerm_subnet.pgsql_subnet.id

  private_service_connection {
    name                           = "pgsql-private-connection"
    private_connection_resource_id = azurerm_postgresql_flexible_server.pgsql.id
    subresource_names              = ["postgresqlServer"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "pgsql-dns-zone-group"
    private_dns_zone_ids = [azurerm_private_dns_zone.pgsql_dns_zone.id]
  }

  depends_on = [azurerm_postgresql_flexible_server.pgsql]
}

resource "azurerm_kubernetes_cluster" "aks" {
  name                = "poc-aks01"
  location            = azurerm_resource_group.example.location
  resource_group_name = azurerm_resource_group.example.name
  dns_prefix          = "pocaks01"

  default_node_pool {
    name       = "default"
    node_count = 1
    vm_size    = "Standard_D2_v2"
  }

  network_profile {
    network_plugin = "azure"
    service_cidr   = "10.0.2.0/24"
    dns_service_ip = "10.0.2.10"
  }

  identity {
    type = "SystemAssigned"
  }

  depends_on = [azurerm_subnet.aks_subnet]
}

output "client_certificate" {
  value     = azurerm_kubernetes_cluster.example.kube_config[0].client_certificate
  sensitive = true
}

output "kube_config" {
  value = azurerm_kubernetes_cluster.example.kube_config_raw

  sensitive = true
}