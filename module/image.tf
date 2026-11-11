locals {
  factory_profiles = { for k, p in var.image_profiles : k => p if p.installer_image == null }
  ext_profiles     = { for k, p in local.factory_profiles : k => p if length(p.system_extensions) > 0 }
  # accept "iscsi-tools" and "siderolabs/iscsi-tools"
  ext_wanted = { for k, p in local.ext_profiles : k => distinct([for e in p.system_extensions : trimprefix(e, "siderolabs/")]) }
}
# Ask the factory which of the wanted extensions exist FOR THIS Talos version.
data "talos_image_factory_extensions_versions" "this" {
  for_each = local.ext_profiles
  talos_version = var.talos_version
  filters = {
    names = distinct(concat(local.ext_wanted[each.key], [for e in local.ext_wanted[each.key] : "siderolabs/${e}"]))
  }
}
locals {
  ext_resolved = {
    for k, d in data.talos_image_factory_extensions_versions.this : k => [
      for e in d.extensions_info : e.name if contains(local.ext_wanted[k], trimprefix(e.name, "siderolabs/"))
    ]
  }
  ext_missing = {
    for k, wanted in local.ext_wanted : k => [
      for w in wanted : w if !contains([for n in local.ext_resolved[k] : trimprefix(n, "siderolabs/")], w)
    ]
  }
  schematics = {
    for k, p in local.factory_profiles : k => {
      for top, val in {
        customization = {
          for key, v in {
            extraKernelArgs  = length(p.extra_kernel_args) > 0 ? p.extra_kernel_args : null
            meta             = length(p.meta) > 0 ? [for m in p.meta : { key = m.key, value = m.value }] : null
            systemExtensions = length(try(local.ext_resolved[k], [])) > 0 ? { officialExtensions = local.ext_resolved[k] } : null
          } : key => v if v != null
        }
        overlay = p.overlay == null ? null : {
          for key, v in { name = p.overlay.name, image = p.overlay.image, options = p.overlay.options } : key => v if v != null
        }
      } : top => val if val != null
    }
  }
}
resource "talos_image_factory_schematic" "this" {
  for_each = local.schematics
  schematic  = yamlencode(each.value)
  depends_on = [terraform_data.preflight]
}
data "talos_image_factory_urls" "this" {
  for_each = local.schematics
  talos_version = var.talos_version
  schematic_id  = talos_image_factory_schematic.this[each.key].id
  platform      = var.platform
  architecture  = var.architecture
}
locals {
  profile_urls = { for k, d in data.talos_image_factory_urls.this : k => d.urls }
  # The single source of truth
  installer_images = {
    for k, p in var.image_profiles : k => (
      p.installer_image != null ? p.installer_image : (
        p.secureboot ? try(local.profile_urls[k].installer_secureboot, null) : local.profile_urls[k].installer
      )
    )
  }
  iso_urls = {
    for k, p in var.image_profiles : k => (
      p.installer_image != null ? null : (
        p.secureboot ? try(local.profile_urls[k].iso_secureboot, null) : try(local.profile_urls[k].iso, null)
      )
    )
  }
}
