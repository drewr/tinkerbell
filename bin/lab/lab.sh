#!/bin/bash
# Local Tinkerbell lab: Tinkerbell on kind, with QEMU "bare-metal" machines
# running in containers on the kind Docker network. Works without KVM.

set -euo pipefail

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${LAB_DIR}/../.." && pwd)"
STATE_DIR="${LAB_DIR}/.state"

CLUSTER="${LAB_CLUSTER:-tink-lab}"
CONTEXT="kind-${CLUSTER}"
NAMESPACE="tinkerbell"
NETWORK="kind"
QEMU_IMAGE="tink-lab/qemu:dev"
# Set TINK_IMAGE to use a published image instead of building from this checkout.
TINK_IMAGE="${TINK_IMAGE:-}"

function usage() {
  cat <<EOF
Usage: $0 <command> [args]

Commands:
  up                        Create the kind cluster, build Tinkerbell from this checkout, install the chart
  vm <name> <n> [bios|uefi] Create Hardware <name> and start a QEMU machine for it (n: 1-254, default uefi)
  smoke <name>              Run the smoke Workflow on machine <name> and check its disk
  reset <name>              Reboot machine <name>, which network-boots again
  console <name>            Follow the HookOS kernel console (ttyS1) of machine <name>
  screenshot <name>         Save a PNG of the VGA display of machine <name>
  rm-vm <name>              Stop machine <name> and delete its Hardware and disk
  status                    Show pods, Hardware, Workflows, and machines
  down                      Delete all machines and the kind cluster

Environment:
  TINK_IMAGE   Use this Tinkerbell image instead of building one (e.g. ghcr.io/tinkerbell/tinkerbell:latest)
  LAB_CLUSTER  kind cluster name (default: tink-lab)
EOF
}

# Re-run under nix-shell when host tools are missing.
function ensure_tools() {
  local missing=()
  for t in kind helm kubectl go; do
    command -v "$t" >/dev/null || missing+=("$t")
  done
  [[ ${#missing[@]} -eq 0 ]] && return
  if [[ -n "${LAB_IN_NIX_SHELL:-}" ]] || ! command -v nix-shell >/dev/null; then
    echo "missing tools: ${missing[*]}" >&2
    exit 1
  fi
  export LAB_IN_NIX_SHELL=1
  exec nix-shell -p kind kubernetes-helm kubectl go --run "$(printf '%q ' "$0" "$@")"
}

function k() { kubectl --context "${CONTEXT}" -n "${NAMESPACE}" "$@"; }

function node_ip() {
  docker inspect "${CLUSTER}-control-plane" -f "{{(index .NetworkSettings.Networks \"${NETWORK}\").IPAddress}}"
}

function network_gateway() {
  docker network inspect "${NETWORK}" -f '{{range .IPAM.Config}}{{if .Gateway}}{{println .Gateway}}{{end}}{{end}}' | grep -v : | head -1
}

# Machines get a.b.100.<n> on the kind /16. Docker assigns container IPs
# from the bottom of the range, so this stays clear of them.
function vm_ip() {
  local ip; ip="$(node_ip)"
  echo "${ip%.*.*}.100.$1"
}

function vm_mac() { printf '52:54:00:1a:b0:%02x' "$1"; }

function vm_container() { echo "${CLUSTER}-vm-$1"; }

# Remove files the QEMU container created as root.
function rm_state() {
  docker run --rm -v "${STATE_DIR}:/state" alpine:3.22 sh -c "rm -rf /state/$1"
}

function cmd_up() {
  [[ -c /dev/net/tun ]] || { echo "/dev/net/tun is required for the QEMU machines" >&2; exit 1; }

  if ! kind get clusters 2>/dev/null | grep -qx "${CLUSTER}"; then
    kind create cluster --name "${CLUSTER}"
  fi

  local repo tag
  if [[ -z "${TINK_IMAGE}" ]]; then
    local arch; arch="$(go env GOARCH)"
    echo "building tinkerbell (linux/${arch}) from ${REPO_ROOT}"
    (cd "${REPO_ROOT}" && CGO_ENABLED=0 GOOS=linux GOARCH="${arch}" go build -ldflags="-s -w" -o "out/tinkerbell-linux-${arch}" ./cmd/tinkerbell)
    # Dockerfile.tinkerbell copies the license bundle; `make third-party-licenses`
    # generates the real one. A placeholder is enough for a local image.
    [[ -f "${REPO_ROOT}/out/THIRD_PARTY_LICENSES-linux-${arch}" ]] || : > "${REPO_ROOT}/out/THIRD_PARTY_LICENSES-linux-${arch}"
    TINK_IMAGE="tink-lab/tinkerbell:dev"
    docker build -t "${TINK_IMAGE}" -f "${REPO_ROOT}/Dockerfile.tinkerbell" "${REPO_ROOT}"
    kind load docker-image "${TINK_IMAGE}" --name "${CLUSTER}"
  fi
  repo="${TINK_IMAGE%:*}"
  tag="${TINK_IMAGE##*:}"

  local ip; ip="$(node_ip)"
  helm --kube-context "${CONTEXT}" upgrade --install tinkerbell "${REPO_ROOT}/helm/tinkerbell" \
    --create-namespace --namespace "${NAMESPACE}" \
    -f "${LAB_DIR}/values.yaml" \
    --set "publicIP=${ip}" \
    --set "artifactsFileServer=http://${ip}:7173" \
    --set "deployment.image=${repo}" \
    --set "deployment.imageTag=${tag}" \
    --wait --timeout 10m
  # Pick up a rebuilt image with the same tag. The Recreate strategy stops the
  # old pod first, freeing its host ports.
  k rollout restart deployment/tinkerbell
  k rollout status deployment/tinkerbell --timeout 5m

  echo "waiting for HookOS artifacts"
  until docker run --rm --network "${NETWORK}" curlimages/curl -sfI "http://${ip}:7173/initramfs-x86_64" >/dev/null; do
    sleep 5
  done
  k apply -f "${LAB_DIR}/manifests/smoke-template.yaml"
  echo "lab is up: Tinkerbell at ${ip}"
}

function cmd_vm() {
  local name="${1:?name required}" n="${2:?n required}" firmware="${3:-uefi}"
  [[ "${n}" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= 254 )) || { echo "n must be 1-254" >&2; exit 1; }
  [[ "${firmware}" == uefi || "${firmware}" == bios ]] || { echo "firmware must be bios or uefi" >&2; exit 1; }
  [[ "${firmware}" == bios ]] && echo "note: BIOS machines boot undionly.kpxe, which downloads HookOS at ~60 KB/s under TCG"

  local mac ip gw uefi=false
  mac="$(vm_mac "${n}")"
  ip="$(vm_ip "${n}")"
  gw="$(network_gateway)"
  [[ "${firmware}" == uefi ]] && uefi=true

  k apply -f - <<EOF
apiVersion: tinkerbell.org/v1alpha1
kind: Hardware
metadata:
  name: ${name}
  namespace: ${NAMESPACE}
spec:
  disks:
    - device: /dev/vda
  interfaces:
    - dhcp:
        arch: x86_64
        hostname: ${name}
        mac: ${mac}
        uefi: ${uefi}
        lease_time: 86400
        name_servers: ["1.1.1.1", "8.8.8.8"]
        ip:
          address: ${ip}
          netmask: 255.255.0.0
          gateway: ${gw}
      netboot:
        allowPXE: true
        allowWorkflow: true
EOF

  docker build -q -t "${QEMU_IMAGE}" "${LAB_DIR}/qemu" >/dev/null
  mkdir -p "${STATE_DIR}/${name}"
  docker rm -f "$(vm_container "${name}")" >/dev/null 2>&1 || true
  docker run -d --name "$(vm_container "${name}")" --network "${NETWORK}" \
    --cap-add NET_ADMIN --device /dev/net/tun \
    -e MAC="${mac}" -e FIRMWARE="${firmware}" \
    -v "${STATE_DIR}/${name}:/out" \
    "${QEMU_IMAGE}" >/dev/null
  echo "started ${name}: mac=${mac} ip=${ip} firmware=${firmware}"
}

function monitor_cmd() {
  docker exec "$(vm_container "$1")" sh -c "echo '$2' | socat - UNIX-CONNECT:/out/monitor.sock" >/dev/null
}

function cmd_reset() {
  local name="${1:?name required}"
  monitor_cmd "${name}" system_reset
}

function cmd_smoke() {
  local name="${1:?name required}" wf mac
  wf="${name}-smoke"
  mac="$(k get hardware "${name}" -o jsonpath='{.spec.interfaces[0].dhcp.mac}')"
  k delete workflow "${wf}" --ignore-not-found
  k apply -f - <<EOF
apiVersion: tinkerbell.org/v1alpha1
kind: Workflow
metadata:
  name: ${wf}
  namespace: ${NAMESPACE}
spec:
  templateRef: smoke
  hardwareRef: ${name}
  hardwareMap:
    device_1: ${mac}
EOF
  # Reboot so the machine network-boots into HookOS and picks up the Workflow.
  cmd_reset "${name}"
  echo "waiting for workflow ${wf}"
  local state=""
  for _ in $(seq 1 180); do
    state="$(k get workflow "${wf}" -o jsonpath='{.status.state}')"
    case "${state}" in SUCCESS | FAILED | TIMEOUT) break ;; esac
    sleep 10
  done
  k get workflow "${wf}"
  [[ "${state}" == SUCCESS ]] || { echo "workflow ended in state '${state}'" >&2; exit 1; }

  local marker
  marker="$(docker exec "$(vm_container "${name}")" sh -c \
    'qemu-img convert -U -O raw /out/disk.qcow2 /tmp/d.raw && dd if=/tmp/d.raw bs=512 skip=2048 count=1 2>/dev/null | tr -d "\0"; rm -f /tmp/d.raw')"
  if [[ "${marker}" == tinkerbell-lab-* ]]; then
    echo "disk check passed: ${marker}"
  else
    echo "disk check failed: marker not found at sector 2048" >&2
    exit 1
  fi
}

function cmd_console() {
  local name="${1:?name required}"
  tail -F "${STATE_DIR}/${name}/ttyS1.log"
}

function cmd_screenshot() {
  local name="${1:?name required}"
  monitor_cmd "${name}" "screendump /out/screen.png -f png"
  echo "${STATE_DIR}/${name}/screen.png"
}

function cmd_rm_vm() {
  local name="${1:?name required}"
  docker rm -f "$(vm_container "${name}")" >/dev/null 2>&1 || true
  k delete workflow "${name}-smoke" --ignore-not-found
  k delete hardware "${name}" --ignore-not-found
  [[ -d "${STATE_DIR}/${name}" ]] && rm_state "${name}"
  true
}

function cmd_status() {
  k get pods -o wide
  k get hardware,workflow
  docker ps --filter "name=${CLUSTER}-vm-" --format 'table {{.Names}}\t{{.Status}}'
}

function cmd_down() {
  local c
  for c in $(docker ps -aq --filter "name=${CLUSTER}-vm-"); do docker rm -f "${c}" >/dev/null; done
  kind delete cluster --name "${CLUSTER}"
  [[ -d "${STATE_DIR}" ]] && rm_state "*"
  true
}

cmd="${1:-}"
[[ -z "${cmd}" || "${cmd}" == -h || "${cmd}" == --help ]] && { usage; exit 0; }
ensure_tools "$@"
shift
case "${cmd}" in
  up) cmd_up "$@" ;;
  vm) cmd_vm "$@" ;;
  smoke) cmd_smoke "$@" ;;
  reset) cmd_reset "$@" ;;
  console) cmd_console "$@" ;;
  screenshot) cmd_screenshot "$@" ;;
  rm-vm) cmd_rm_vm "$@" ;;
  status) cmd_status "$@" ;;
  down) cmd_down "$@" ;;
  *) usage; exit 1 ;;
esac
