#!/usr/bin/env bash
# Called by the module (terraform_data.rolling_upgrade, local-exec) when auto_upgrade.enabled = true.
# Everything comes from environment variables, nothing is read from Terraform state/outputs
#
# Idempotent: a node is upgraded only when its running Talos version or schematic ID differs from the target,
# so re-running after a failure continues where it stopped. Needs: talosctl, jq.
set -euo pipefail

: "${TALOSCONFIG_YAML:?TALOSCONFIG_YAML is required}"
: "${UPGRADE_PLAN:?UPGRADE_PLAN is required}"
: "${ENDPOINTS:?ENDPOINTS is required}"
TALOSCTL="${TALOSCTL:-talosctl}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-15m}"
HEALTH_MODE="${HEALTH_MODE:-full}"

for bin in "$TALOSCTL" jq; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: '$bin' is not installed on the machine running terraform" >&2; exit 1; }
done

TMP="$(mktemp -d)"
chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT
( umask 077; printf '%s' "$TALOSCONFIG_YAML" > "$TMP/talosconfig" )

tc() { "$TALOSCTL" --talosconfig "$TMP/talosconfig" -e "$ENDPOINTS" "$@"; }

HEALTH_NODE="${ENDPOINTS%%,*}"

retry() {
  local n="$1" s="$2"; shift 2
  local i
  for ((i = 1; i <= n; i++)); do
    if "$@"; then return 0; fi
    sleep "$s"
  done
  return 1
}

running_version() { tc -n "$1" version 2>/dev/null | awk '/Tag:/ {t=$2} END {print t}'; }
running_schematic() {
  tc -n "$1" get extensions -o json 2>/dev/null \
    | jq -rs '[.[] | select(.spec.metadata.name == "schematic") | .spec.metadata.version][0] // ""' 2>/dev/null || true
}
api_up() { tc -n "$1" version >/dev/null 2>&1; }

total="$(jq 'length' <<<"$UPGRADE_PLAN")"
echo "Upgrade plan: $total node(s), health mode: $HEALTH_MODE"

for ((i = 0; i < total; i++)); do
  field() { jq -r ".[$i].$1 // \"\"" <<<"$UPGRADE_PLAN"; }
  name="$(field name)"; role="$(field role)"; ip="$(field ip)"
  image="$(field image)"; want_id="$(field schematic_id)"; want_ver="$(field version)"

  echo "==> $name ($role, $ip)"
  if [[ -z "$image" ]]; then echo "    no installer image defined, skipping"; continue; fi

  if ! retry 30 10 api_up "$ip"; then
    echo "ERROR: $name ($ip) does not answer on the Talos API, aborting to keep the cluster safe" >&2
    exit 1
  fi

  have_ver="$(running_version "$ip")"
  have_id="$(running_schematic "$ip")"
  echo "    running: version=${have_ver:-?} schematic=${have_id:-unknown}"
  echo "    target : version=$want_ver schematic=${want_id:-custom installer}"

  if [[ -n "$want_id" ]]; then
    if [[ "$have_ver" == "$want_ver" && "$have_id" == "$want_id" ]]; then echo "    up to date"; continue; fi
  else
    if [[ "$have_ver" == "$want_ver" ]]; then
      echo "    custom installer image: same Talos version, skipping (run talosctl upgrade manually if the image content changed)"
      continue
    fi
  fi

  echo "    upgrading with $image"
  tc -n "$ip" upgrade --image "$image" --wait

  retry 60 10 api_up "$ip" || { echo "ERROR: $name did not come back after upgrade" >&2; exit 1; }

  if [[ "$HEALTH_MODE" == "full" ]]; then
    tc -n "$HEALTH_NODE" health --wait-timeout "$HEALTH_TIMEOUT"
  elif [[ "$role" == "controlplane" ]]; then
    retry 60 10 tc -n "$ip" etcd status >/dev/null 2>&1 || { echo "ERROR: etcd on $name is not healthy" >&2; exit 1; }
  fi

  if [[ -n "$want_id" ]]; then
    now_id="$(running_schematic "$ip")"
    if [[ -n "$now_id" && "$now_id" != "$want_id" ]]; then
      echo "ERROR: $name reports schematic $now_id, expected $want_id" >&2
      exit 1
    fi
  fi
  echo "    $name OK"
done

echo "All nodes are on the target image."
