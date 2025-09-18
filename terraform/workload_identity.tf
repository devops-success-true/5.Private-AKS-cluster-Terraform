# User-assigned managed identity for workloads
resource "azurerm_user_assigned_identity" "test_prod" {
  name                = "test-prod"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

# Federated identity credential linking AKS OIDC to the UAMI
resource "azurerm_federated_identity_credential" "test_prod" {
  name                = "test-prod"
  resource_group_name = azurerm_resource_group.rg.name
  parent_id           = azurerm_user_assigned_identity.test_prod.id

  # This comes from AKS OIDC issuer
  issuer              = module.aks_cluster.oidc_issuer_url
  audience            = ["api://AzureADTokenExchange"]

  # Link to a Kubernetes service account (namespace: dev, name: my-account)
  subject             = "system:serviceaccount:dev:my-account"

  depends_on = [module.aks_cluster]
}

# -------------------------
# Assign permissions to the workload identity
# -------------------------

# 1. Key Vault Secrets User - allow pods to read secrets from Key Vault
resource "azurerm_role_assignment" "test_prod_kv" {
  scope                = module.key_vault.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.test_prod.principal_id
}

# 2. Storage Blob Data Reader - allow pods to pull artifacts, configs, or logs from a storage account
resource "azurerm_role_assignment" "test_prod_blob" {
  scope                = module.storage_account.id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_user_assigned_identity.test_prod.principal_id
}

# 3. AcrPull - allow pods to pull container images from ACR
resource "azurerm_role_assignment" "test_prod_acr" {
  scope                = module.container_registry.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.test_prod.principal_id
}
