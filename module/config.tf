locals {
  talos_minor = tonumber(regex("^v[0-9]+\\.([0-9]+)\\.", var.talos_version)[0])
  config_contract = (
    var.config_contract_version != null ? var.config_contract_version :
    (local.talos_minor >= 14 ? "v1.13.0" : var.talos_version)
  )

  contract_minor       = tonumber(regex("^v[0-9]+\\.([0-9]+)\\.", local.config_contract)[0])
  hostname_as_document = local.contract_minor >= 12
  controlplanes = { for k, n in var.nodes : k => n if n.role == "controlplane" }
  workers       = { for k, n in var.nodes : k => n if n.role == "worker" }
  cp_keys        = sort(keys(local.controlplanes))
  cp_ips         = [for k in local.cp_keys : local.controlplanes[k].ip]
  worker_keys    = sort(keys(local.workers))
  worker_ips     = [for k in local.worker_keys : local.workers[k].ip]
  bootstrap_node = var.bootstrap_node != null ? var.bootstrap_node : local.cp_keys[0]
  bootstrap_ip   = local.controlplanes[local.bootstrap_node].ip

  # disks
  disk_choice = {
    for k, n in var.nodes : k => {
      path = n.install_disk != null ? n.install_disk : (n.install_disk_selector != null ? null : var.default_install_disk)
      selector = n.install_disk_selector != null ? n.install_disk_selector : (
        n.install_disk != null ? null : (var.default_install_disk == null ? var.default_install_disk_selector : null)
      )
    }
  }

  # encryption
  encryption_keys = {
    tpm    = { slot = 0, tpm = {} }
    nodeID = { slot = 0, nodeID = {} }
  }
  encryption_key = lookup(local.encryption_keys, var.disk_encryption_mode, local.encryption_keys.nodeID)

  # cluster-wide config
  kubelet_cfg = {
    for key, val in {
      extraArgs   = length(var.kubelet_extra_args) > 0 ? var.kubelet_extra_args : null
      nodeIP      = length(var.node_subnets) > 0 ? { validSubnets = var.node_subnets } : null
      extraMounts = length(var.kubelet_extra_mounts) > 0 ? [for m in var.kubelet_extra_mounts : { destination = m.destination, type = m.type, source = m.source, options = m.options }] : null
    } : key => val if val != null
  }
  common_machine = {
    for key, val in {
      time    = length(var.ntp_servers) > 0 ? { servers = var.ntp_servers } : null
      sysctls = length(var.sysctls) > 0 ? var.sysctls : null
      kubelet = length(local.kubelet_cfg) > 0 ? local.kubelet_cfg : null
      kernel = length(var.kernel_modules) > 0 ? {
        modules = [for m in var.kernel_modules : { for k2, v2 in { name = m.name, parameters = length(m.parameters) > 0 ? m.parameters : null } : k2 => v2 if v2 != null }]
      } : null
      registries = length(var.registry_mirrors) > 0 ? {
        mirrors = { for host, eps in var.registry_mirrors : host => { endpoints = eps } }
      } : null
      systemDiskEncryption = var.disk_encryption_mode != "none" ? {
        state     = { provider = "luks2", keys = [local.encryption_key] }
        ephemeral = { provider = "luks2", keys = [local.encryption_key] }
      } : null
    } : key => val if val != null
  }
  discovery_cfg = (var.discovery.enabled && var.discovery.service_enabled && var.discovery.service_endpoint == null) ? null : {
    enabled = var.discovery.enabled
    registries = {
      service = { for k2, v2 in { disabled = !var.discovery.service_enabled, endpoint = var.discovery.service_endpoint } : k2 => v2 if v2 != null }
    }
  }
  common_cluster = {
    for key, val in {
      network = {
        cni            = { name = var.cni }
        podSubnets     = var.pod_subnets
        serviceSubnets = var.service_subnets
      }
      proxy           = { disabled = var.disable_kube_proxy }
      inlineManifests = length(var.inline_manifests) > 0 ? [for m in var.inline_manifests : { name = m.name, contents = m.contents }] : null
      discovery       = local.discovery_cfg
    } : key => val if val != null
  }
  common_patches = concat(
    length(local.common_machine) > 0 ? [yamlencode({ machine = local.common_machine })] : [],
    [yamlencode({ cluster = local.common_cluster })],
    var.common_config_patches,
  )

  # control plane config
  cp_cluster = {
    for key, val in {
      allowSchedulingOnControlPlanes = var.allow_scheduling_on_controlplanes
      etcd                           = length(var.node_subnets) > 0 ? { advertisedSubnets = var.node_subnets } : null
      apiServer = (length(var.extra_cert_sans) + length(var.control_plane_extra_args.apiserver)) > 0 ? {
        for k2, v2 in {
          certSANs  = length(var.extra_cert_sans) > 0 ? var.extra_cert_sans : null
          extraArgs = length(var.control_plane_extra_args.apiserver) > 0 ? var.control_plane_extra_args.apiserver : null
        } : k2 => v2 if v2 != null
      } : null
      controllerManager = length(var.control_plane_extra_args.controller_manager) > 0 ? { extraArgs = var.control_plane_extra_args.controller_manager } : null
      scheduler         = length(var.control_plane_extra_args.scheduler) > 0 ? { extraArgs = var.control_plane_extra_args.scheduler } : null
    } : key => val if val != null
  }
  controlplane_patches = concat(
    local.common_patches,
    [yamlencode({ cluster = local.cp_cluster })],
    var.controlplane_config_patches,
  )
  worker_patches = concat(local.common_patches, var.worker_config_patches)

  # networking
  network_interfaces = {
    for k, n in var.nodes : k => (n.network == null ? [] : [
      for i in n.network.interfaces : {
        for key, val in {
          interface      = i.bond != null ? i.bond.name : (i.hardware_addr == null ? i.name : null)
          deviceSelector = (i.bond == null && i.hardware_addr != null) ? { hardwareAddr = lower(i.hardware_addr) } : null
          bond = i.bond == null ? null : {
            for bk, bv in {
              mode            = i.bond.mode
              deviceSelectors = [for m in i.bond.hardware_addrs : { hardwareAddr = lower(m) }]
              lacpRate        = i.bond.lacp_rate
              xmitHashPolicy  = i.bond.xmit_hash_policy
            } : bk => bv if bv != null
          }
          dhcp      = (i.dhcp != null ? i.dhcp : length(i.addresses) == 0) ? true : null
          addresses = length(i.addresses) > 0 ? i.addresses : null
          mtu       = i.mtu
          routes = (i.gateway != null || length(i.routes) > 0) ? concat(
            [for g in [i.gateway] : { network = "0.0.0.0/0", gateway = g } if g != null],
            [for r in i.routes : { for rk, rv in { network = r.network, gateway = r.gateway, metric = r.metric } : rk => rv if rv != null }],
          ) : null
          vlans = length(i.vlans) > 0 ? [
            for v in i.vlans : {
              for vk, vv in {
                vlanId    = v.id
                dhcp      = (v.dhcp != null ? v.dhcp : length(v.addresses) == 0) ? true : null
                addresses = length(v.addresses) > 0 ? v.addresses : null
                mtu       = v.mtu
                routes = (v.gateway != null || length(v.routes) > 0) ? concat(
                  [for g in [v.gateway] : { network = "0.0.0.0/0", gateway = g } if g != null],
                  [for r in v.routes : { for rk, rv in { network = r.network, gateway = r.gateway, metric = r.metric } : rk => rv if rv != null }],
                ) : null
              } : vk => vv if vv != null
            }
          ] : null
          vip = (n.role == "controlplane" && var.controlplane_vip != null && i.vip) ? { ip = var.controlplane_vip } : null
        } : key => val if val != null
      }
    ])
  }
  network_patch = {
    for k, n in var.nodes : k => {
      for key, val in {
        hostname    = local.hostname_as_document ? null : k
        interfaces  = length(local.network_interfaces[k]) > 0 ? local.network_interfaces[k] : null
        nameservers = try(length(n.network.nameservers) > 0 ? n.network.nameservers : null, null)
      } : key => val if val != null
    }
  }

  # per-node patches
  node_patches = {
    for k, n in var.nodes : k => concat(
      [yamlencode({
        machine = {
          for mk, mv in {
            network    = length(local.network_patch[k]) > 0 ? local.network_patch[k] : null
            nodeLabels = n.labels
            nodeTaints = n.taints
            install = {
              for ik, iv in {
                image        = local.installer_images[n.profile]
                disk         = local.disk_choice[k].path
                diskSelector = local.disk_choice[k].selector
                wipe         = false
              } : ik => iv if iv != null
            }
          } : mk => mv if mv != null
        }
      })],
      local.hostname_as_document ? [yamlencode({
        apiVersion = "v1alpha1"
        kind       = "HostnameConfig"
        hostname   = k
        auto       = "off"
      })] : [],
      n.config_patches,
    )
  }
}

# FF
resource "terraform_data" "preflight" {
  lifecycle {
    precondition {
      condition     = var.allow_non_ha || length(local.controlplanes) >= 3
      error_message = "Production needs >= 3 control planes. Set allow_non_ha = true for dev."
    }
    precondition {
      condition     = alltrue([for n in values(var.nodes) : contains(keys(var.image_profiles), n.profile)])
      error_message = "A node references a profile that is not defined in image_profiles."
    }
    precondition {
      condition     = contains(keys(local.controlplanes), local.bootstrap_node)
      error_message = "bootstrap_node must be a controlplane node key."
    }
    precondition {
      condition     = length(distinct([for n in values(var.nodes) : n.ip])) == length(var.nodes)
      error_message = "Node IPs must be unique."
    }
    precondition {
      condition     = alltrue([for k, d in local.disk_choice : (d.path != null) != (d.selector != null)])
      error_message = "Every node needs exactly one install target: install_disk / install_disk_selector, or default_install_disk / default_install_disk_selector."
    }
    precondition {
      condition = alltrue(flatten([
        for n in values(var.nodes) : n.network == null ? [] : [for i in n.network.interfaces : (i.bond != null || i.hardware_addr != null || i.name != null)]
      ]))
      error_message = "Every network interface needs bond, hardware_addr or name."
    }
    precondition {
      condition = var.controlplane_vip == null || alltrue([
        for n in values(local.controlplanes) : try(length([for i in n.network.interfaces : i if i.vip]) == 1, false)
      ])
      error_message = "controlplane_vip requires exactly one interface with vip = true in nodes[*].network on every control plane."
    }
    precondition {
      condition     = alltrue([for k, m in local.ext_missing : length(m) == 0])
      error_message = "Extensions not found for Talos ${var.talos_version}: ${jsonencode(local.ext_missing)}. Check names at https://factory.talos.dev or the siderolabs/extensions repo."
    }
  }
}

# The root of trust of the cluster. TODO: encrypt
resource "talos_machine_secrets" "this" {
  talos_version = var.talos_version
  depends_on = [terraform_data.preflight]
  lifecycle {
    prevent_destroy = true
  }
}
data "talos_machine_configuration" "this" {
  for_each = toset(["controlplane", "worker"])
  cluster_name       = var.cluster_name
  cluster_endpoint   = var.cluster_endpoint
  machine_type       = each.key
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = local.config_contract
  kubernetes_version = var.kubernetes_version
  docs               = false
  examples           = false
  config_patches = each.key == "controlplane" ? local.controlplane_patches : local.worker_patches
}
