# ---------------------------------------------------------------------------
# Optional: roll new Talos images out to running nodes from `terraform apply`.
#
# Why it is opt-in: an upgrade reboots nodes. The script upgrades ONE node at a time (control planes first),
# waits for the node and cluster health, and skips nodes that already run the target version + schematic.
# It runs on the machine that executes terraform and needs `talosctl` and `jq` there plus network access
# to the nodes (50000/tcp). It cannot work in a remote-execution runner without those.
# ---------------------------------------------------------------------------
locals {
  upgrade_plan = [
    for k in concat(local.cp_keys, local.worker_keys) : {
      name         = k
      role         = var.nodes[k].role
      ip           = var.nodes[k].ip
      image        = local.installer_images[var.nodes[k].profile]
      schematic_id = try(talos_image_factory_schematic.this[var.nodes[k].profile].id, "")
      version      = var.talos_version
    }
  ]
}

resource "terraform_data" "rolling_upgrade" {
  count = var.auto_upgrade.enabled ? 1 : 0

  # Re-runs only when a target image changes (profile content or talos_version).
  triggers_replace = {
    plan = local.upgrade_plan
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = "bash \"${path.module}/scripts/apply-upgrade.sh\""

    environment = {
      TALOSCONFIG_YAML = data.talos_client_configuration.this.talos_config
      UPGRADE_PLAN     = jsonencode(local.upgrade_plan)
      ENDPOINTS        = join(",", local.cp_ips)
      HEALTH_TIMEOUT   = var.auto_upgrade.health_timeout
      HEALTH_MODE      = var.cni == "none" ? "basic" : "full"
      TALOSCTL         = var.auto_upgrade.talosctl
    }
  }

  # Machine configs (with the new machine.install.image) first, upgrade afterwards.
  depends_on = [
    talos_machine_configuration_apply.controlplane,
    talos_machine_bootstrap.this,
    talos_machine_configuration_apply.worker,
    data.talos_cluster_health.this,
  ]
}
