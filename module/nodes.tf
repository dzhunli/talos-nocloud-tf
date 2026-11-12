# order: control planes -> bootstrap (once) -> workers -> kubeconfig -> health check.
resource "talos_machine_configuration_apply" "controlplane" {
  for_each                    = local.controlplanes
  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.this["controlplane"].machine_configuration
  node                        = each.value.ip
  endpoint                    = each.value.ip
  apply_mode                  = var.apply_mode
  config_patches              = local.node_patches[each.key]
}
# Runs once. ignore_changes = all so editing inputs can never re-bootstrap a live cluster.
resource "talos_machine_bootstrap" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.bootstrap_ip
  endpoint             = local.bootstrap_ip
  depends_on           = [talos_machine_configuration_apply.controlplane]
  lifecycle {
    ignore_changes = all
  }
}
resource "talos_machine_configuration_apply" "worker" {
  for_each                    = local.workers
  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.this["worker"].machine_configuration
  node                        = each.value.ip
  endpoint                    = each.value.ip
  apply_mode                  = var.apply_mode
  config_patches              = local.node_patches[each.key]
  depends_on                  = [talos_machine_bootstrap.this]
}
resource "talos_cluster_kubeconfig" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.bootstrap_ip
  endpoint             = local.bootstrap_ip
  depends_on           = [talos_machine_bootstrap.this]
}
data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = local.cp_ips # direct control plane IPs, not the VIP/LB
  nodes                = concat(local.cp_ips, local.worker_ips)
}
data "talos_cluster_health" "this" {
  count                  = var.wait_for_health ? 1 : 0
  client_configuration   = talos_machine_secrets.this.client_configuration
  endpoints              = local.cp_ips
  control_plane_nodes    = local.cp_ips
  worker_nodes           = local.worker_ips
  skip_kubernetes_checks = var.cni == "none" # nodes are NotReady until a CNI is installed
  depends_on = [
    talos_machine_configuration_apply.worker,
    talos_cluster_kubeconfig.this,
  ]
}
