############################
# Cluster identity
############################
variable "cluster_name" {
  description = "Cluster name (used in talosconfig and kubeconfig)."
  type        = string
}
variable "cluster_endpoint" {
  description = "Stable Kubernetes API URL (VIP or LB DNS name), e.g. https://k8s.example.com:6443. Never a single node IP in production."
  type        = string
  validation {
    condition     = can(regex("^https://[^/]+:[0-9]+$", var.cluster_endpoint))
    error_message = "cluster_endpoint must look like https://host:6443."
  }
}
variable "controlplane_vip" {
  description = "Optional Talos-native L2 VIP. Requires control planes in one L2 segment and exactly one interface with vip = true in nodes[*].network on every control plane. Leave null when using an external load balancer."
  type        = string
  default     = null
  validation {
    condition     = var.controlplane_vip == null || can(cidrhost("${var.controlplane_vip}/32", 0))
    error_message = "controlplane_vip must be an IP address."
  }
}
variable "extra_cert_sans" {
  description = "Extra SANs for the kube-apiserver certificate (the endpoint host is added automatically)."
  type        = list(string)
  default     = []
}
############################
# Versions and platform
############################
variable "talos_version" {
  description = "Talos version with a leading v (e.g. v1.11.0). Drives machine config generation and Image Factory URLs. Always pin it."
  type        = string
  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+$", var.talos_version))
    error_message = "talos_version must look like v1.11.0."
  }
}
variable "config_contract_version" {
  description = <<-EOT
    Talos "version contract" used to GENERATE the machine config (passed as talos_version to
    data.talos_machine_configuration). It decides which config format the provider emits.
    This module patches the classic v1alpha1 format (machine.install, machine.network, cluster.network, ...).
    Talos >= 1.14 contracts generate new multi-document configs (UnattendedInstallConfig, KubeNetworkConfig,
    KubeProxyConfig, KubeFlannelCNIConfig, HostnameConfig, KubeNodeConfig...) that CONFLICT with those patches.
    null (default) = talos_version for < v1.14, and v1.13.0 for >= v1.14. Nodes running 1.14.x accept it:
    deprecated v1alpha1 fields are still honoured.
  EOT
  type        = string
  default     = null
  validation {
    condition     = var.config_contract_version == null || can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+$", var.config_contract_version))
    error_message = "config_contract_version must look like v1.13.0."
  }
}
variable "kubernetes_version" {
  description = "Kubernetes version, e.g. 1.34.0. Must be supported by talos_version."
  type        = string
}
variable "architecture" {
  description = "CPU architecture of the images: amd64 or arm64."
  type        = string
  default     = "amd64"
  validation {
    condition     = contains(["amd64", "arm64"], var.architecture)
    error_message = "architecture must be amd64 or arm64."
  }
}
variable "platform" {
  description = "Image Factory platform: metal (bare metal, default), nocloud, openstack, aws, hcloud, and so on. You bring the machines, the module configures Talos."
  type        = string
  default     = "metal"
}
############################
# Talos Image Factory
############################
variable "image_profiles" {
  description = <<-EOT
    Named Talos image variants. Every node picks one via nodes[*].profile.
      system_extensions : official extensions, "iscsi-tools" or "siderolabs/iscsi-tools" (both accepted)
      extra_kernel_args : kernel command line additions baked into the image
      meta              : Talos META values (key = number, value = string)
      secureboot        : use the Secure Boot installer and ISO variants
      overlay           : SBC overlay, e.g. { name = "rpi_generic", image = "siderolabs/sbc-raspberrypi" }
      installer_image   : bypass Image Factory and use this installer image as is (air-gapped, own factory, mirror)
  EOT
  type = map(object({
    system_extensions = optional(list(string), [])
    extra_kernel_args = optional(list(string), [])
    meta              = optional(list(object({ key = number, value = string })), [])
    secureboot        = optional(bool, false)
    overlay = optional(object({
      name    = string
      image   = string
      options = optional(any)
    }))
    installer_image = optional(string)
  }))
  default = { default = {} }
}
############################
# Nodes
############################
variable "default_install_disk" {
  description = "Disk path Talos installs to (e.g. /dev/nvme0n1). Set this or default_install_disk_selector. A wrong disk means data loss."
  type        = string
  default     = null
}
variable "default_install_disk_selector" {
  description = "Talos diskSelector, e.g. { type = \"nvme\", size = \">= 200GB\" }. Used when a node sets neither install_disk nor install_disk_selector and default_install_disk is null."
  type        = map(string)
  default     = null
}
variable "nodes" {
  description = <<-EOT
    Map of node name => spec. The key becomes the hostname.
      ip      : address the Talos API answers on right now (maintenance mode on first apply)
      profile : key of image_profiles
      network : optional static, bonded or VLAN networking; omit to keep DHCP
    See the README for examples.
  EOT
  type = map(object({
    role                  = string
    ip                    = string
    profile               = optional(string, "default")
    install_disk          = optional(string)
    install_disk_selector = optional(map(string))
    labels                = optional(map(string), {})
    taints                = optional(map(string), {}) # "value:Effect"
    network = optional(object({
      nameservers = optional(list(string), [])
      interfaces = list(object({
        name          = optional(string)
        hardware_addr = optional(string)
        addresses     = optional(list(string), [])
        dhcp          = optional(bool) # default: true
        gateway       = optional(string)
        routes        = optional(list(object({ network = string, gateway = string, metric = optional(number) })), [])
        mtu           = optional(number)
        vip           = optional(bool, false)
        bond = optional(object({
          name             = optional(string, "bond0")
          mode             = optional(string, "802.3ad")
          hardware_addrs   = list(string)
          lacp_rate        = optional(string)
          xmit_hash_policy = optional(string)
        }))
        vlans = optional(list(object({
          id        = number
          addresses = optional(list(string), [])
          dhcp      = optional(bool)
          gateway   = optional(string)
          routes    = optional(list(object({ network = string, gateway = string, metric = optional(number) })), [])
          mtu       = optional(number)
        })), [])
      }))
    }))
    config_patches = optional(list(string), []) # raw YAML, strategic merge, applied last
  }))

  validation {
    condition     = alltrue([for n in values(var.nodes) : contains(["controlplane", "worker"], n.role)])
    error_message = "role must be controlplane or worker."
  }
  validation {
    condition     = length([for n in values(var.nodes) : n if n.role == "controlplane"]) % 2 == 1
    error_message = "Need an odd number of controlplane nodes (1, 3, 5) for etcd quorum."
  }
  validation {
    condition     = alltrue([for k in keys(var.nodes) : can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", k))])
    error_message = "Node keys are hostnames: lowercase letters, digits, hyphens."
  }
}

variable "allow_non_ha" {
  description = "Allow fewer than 3 control planes (dev and test only)."
  type        = bool
  default     = false
}
variable "bootstrap_node" {
  description = "Node key to bootstrap etcd on. Default: the first control plane by name."
  type        = string
  default     = null
}
############################
# Cluster behaviour
############################
variable "node_subnets" {
  description = "Subnets used for the kubelet node IP and the etcd advertise address. Set on multi-NIC machines."
  type        = list(string)
  default     = []
}
variable "pod_subnets" {
  description = "Pod CIDRs."
  type        = list(string)
  default     = ["10.228.0.0/16"]
}
variable "service_subnets" {
  description = "Service CIDRs."
  type        = list(string)
  default     = ["10.96.0.0/12"]
}
variable "cni" {
  description = "none = bring your own CNI (Cilium), flannel = Talos default."
  type        = string
  default     = "none"
  validation {
    condition     = contains(["none", "flannel"], var.cni)
    error_message = "cni must be none or flannel."
  }
}
variable "disable_kube_proxy" {
  description = "Set true when the CNI replaces kube-proxy (for example Cilium with kubeProxyReplacement)."
  type        = bool
  default     = false
}
variable "inline_manifests" {
  description = "Manifests embedded into the machine config and applied at bootstrap (typically the CNI)."
  type        = list(object({ name = string, contents = string }))
  default     = []
}
variable "allow_scheduling_on_controlplanes" {
  description = "Allow regular workloads on control plane nodes."
  type        = bool
  default     = false
}
variable "disk_encryption_mode" {
  description = "none | tpm | nodeID. STATE and EPHEMERAL become LUKS2. tpm needs TPM 2.0 (plus Secure Boot for real protection); nodeID is much weaker."
  type        = string
  default     = "none"
  validation {
    condition     = contains(["none", "tpm", "nodeID"], var.disk_encryption_mode)
    error_message = "disk_encryption_mode must be none, tpm or nodeID."
  }
}
variable "ntp_servers" {
  description = "NTP servers. Empty means the Talos default."
  type        = list(string)
  default     = []
}
variable "registry_mirrors" {
  description = "Registry host => mirror endpoints, e.g. { \"docker.io\" = [\"https://mirror.local\"] }."
  type        = map(list(string))
  default     = {}
}
variable "sysctls" {
  description = "Kernel sysctls applied on every node."
  type        = map(string)
  default     = {}
}
variable "kernel_modules" {
  description = "Kernel modules to load, e.g. [{ name = \"nbd\" }, { name = \"rbd\" }]."
  type        = list(object({ name = string, parameters = optional(list(string), []) }))
  default     = []
}
variable "kubelet_extra_args" {
  description = "Extra kubelet arguments."
  type        = map(string)
  default     = {}
}
variable "kubelet_extra_mounts" {
  description = "Extra kubelet mounts, needed by storage systems such as Longhorn."
  type = list(object({
    destination = string
    source      = string
    type        = optional(string, "bind")
    options     = optional(list(string), ["bind", "rshared", "rw"])
  }))
  default = []
}
variable "control_plane_extra_args" {
  description = "Extra arguments for kube-apiserver, kube-controller-manager and kube-scheduler."
  type = object({
    apiserver          = optional(map(string), {})
    controller_manager = optional(map(string), {})
    scheduler          = optional(map(string), {})
  })
  default = {}
}
variable "discovery" {
  description = "Talos cluster discovery. For air-gapped or privacy-sensitive setups use service_enabled = false or your own service_endpoint."
  type = object({
    enabled          = optional(bool, true)
    service_enabled  = optional(bool, true)
    service_endpoint = optional(string)
  })
  default = {}
}
############################
# Escape hatches (raw YAML strings, strategic-merge patches)
############################
variable "common_config_patches" {
  description = "Raw YAML patches applied to every node."
  type        = list(string)
  default     = []
}
variable "controlplane_config_patches" {
  description = "Raw YAML patches applied to control planes only."
  type        = list(string)
  default     = []
}
variable "worker_config_patches" {
  description = "Raw YAML patches applied to workers only."
  type        = list(string)
  default     = []
}
############################
# Apply behaviour
############################
variable "apply_mode" {
  description = "talos_machine_configuration_apply mode: auto | no_reboot | reboot | staged. Run Terraform with -parallelism=1."
  type        = string
  default     = "auto"
}
variable "wait_for_health" {
  description = "Block until talos_cluster_health passes. Kubernetes-level checks are skipped automatically when cni = none."
  type        = bool
  default     = true
}
variable "auto_upgrade" {
  description = <<-EOT
    Roll new Talos images (changed extensions / kernel args / talos_version) out to running nodes during
    `terraform apply`, one node at a time, control planes first. Off by default because nodes reboot.
    Needs talosctl + jq on the machine running terraform, and network access to the nodes.
      enabled        : turn it on
      health_timeout : per node `talosctl health` timeout
      talosctl       : path/name of the talosctl binary
  EOT
  type = object({
    enabled        = optional(bool, false)
    health_timeout = optional(string, "15m")
    talosctl       = optional(string, "talosctl")
  })
  default = {}
}
