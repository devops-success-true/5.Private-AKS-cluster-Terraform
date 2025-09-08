resource "azurerm_monitor_diagnostic_setting" "settings" {
  # Only create if we have at least one destination (Log Analytics, Storage, or EventHub)
  for_each = (
    (var.log_analytics_workspace_id != null && var.log_analytics_workspace_id != "") ||
    (var.storage_account_id != null && var.storage_account_id != "") ||
    (var.eventhub_authorization_rule_id != null && var.eventhub_authorization_rule_id != "")
  ) ? { "enabled" = true } : {}

  name               = var.name
  target_resource_id = var.target_resource_id

  # These are optional destinations
  log_analytics_workspace_id     = try(var.log_analytics_workspace_id, null)
  log_analytics_destination_type = try(var.log_analytics_destination_type, null)

  eventhub_name                  = try(var.eventhub_name, null)
  eventhub_authorization_rule_id = try(var.eventhub_authorization_rule_id, null)

  storage_account_id             = try(var.storage_account_id, null)

  dynamic "enabled_log" {
    for_each = toset(var.logs)
    content {
      category = each.value
    }
  }

  dynamic "metric" {
    for_each = toset(var.metrics)
    content {
      category = each.value
      enabled  = true
    }
  }
}