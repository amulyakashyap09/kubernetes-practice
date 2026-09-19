#!/usr/bin/env bash
#
# Rebuild the "Kubernetes the Very Hard Way" worker node from scratch.
# Chapter 06: containerd -> runc -> nerdctl -> CNI plugins -> kubelet -> static Pods.
#
# Playgrounds (labs.iximiuz.com) are wiped between sessions, so this script is
# meant to be pasted/curl'ed onto a fresh node and run top to bottom. Every step
# is idempotent: re-running it on a half-configured node is safe.
#
# Usage:
#   ./setup-worker-node.sh                  # run every step
#   ./setup-worker-node.sh containerd runc  # run only the listed steps
#   ./setup-worker-node.sh verify           # just re-check the node
#   ./setup-worker-node.sh --list           # show available steps
#
# Steps: containerd runc nerdctl cni kubelet staticpods verify

set -euo pipefail

#-----------------------------------------------------------------------------
# Versions - bump these as the course moves on.
#-----------------------------------------------------------------------------
CONTAINERD_VERSION="${CONTAINERD_VERSION:-2.2.1}"   # no leading v
RUNC_VERSION="${RUNC_VERSION:-v1.4.0}"
NERDCTL_VERSION="${NERDCTL_VERSION:-2.2.1}"         # no leading v
CNI_PLUGINS_VERSION="${CNI_PLUGINS_VERSION:-v1.9.0}"
KUBE_VERSION="${KUBE_VERSION:-v1.34.0}"

WORKDIR="${WORKDIR:-/tmp/k8s-hard-way}"
STATIC_POD_DIR=/etc/kubernetes/manifests
KUBELET_CONFIG_DIR=/var/lib/kubelet/config.d

#-----------------------------------------------------------------------------
# Helpers
#-----------------------------------------------------------------------------
log()  { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    \033[32mok\033[0m  %s\n' "$*"; }
warn() { printf '    \033[33mwarn\033[0m %s\n' "$*" >&2; }
die()  { printf '\n\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) die "unsupported architecture: $ARCH" ;;
esac

# Write a file as root only if the content differs, and report through the
# FILE_CHANGED global whether it did - callers use that to decide on a restart.
# (Always returns 0 so `set -e` doesn't abort on an unchanged file.)
FILE_CHANGED=0
write_file() {
  local path="$1" content="$2"
  if [ -f "$path" ] && [ "$(sudo cat "$path")" = "$content" ]; then
    ok "$path already up to date"
    FILE_CHANGED=0
    return 0
  fi
  sudo mkdir -p "$(dirname "$path")"
  printf '%s\n' "$content" | sudo tee "$path" >/dev/null
  ok "wrote $path"
  FILE_CHANGED=1
  return 0
}

fetch() {  # fetch <url> <dest>
  curl -fsSL --retry 3 --retry-delay 2 -o "$2" "$1"
}

#-----------------------------------------------------------------------------
# Steps
#-----------------------------------------------------------------------------
step_containerd() {
  log "containerd ${CONTAINERD_VERSION}"

  if command -v containerd >/dev/null && containerd --version | grep -q "v${CONTAINERD_VERSION}"; then
    ok "containerd v${CONTAINERD_VERSION} already installed"
  else
    local tarball="containerd-${CONTAINERD_VERSION}-linux-${ARCH}.tar.gz"
    info "downloading ${tarball}"
    fetch "https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/${tarball}" "${WORKDIR}/${tarball}"
    sudo tar xzofC "${WORKDIR}/${tarball}" /usr/local
    ok "installed $(containerd --version)"
  fi

  # systemd unit
  if [ ! -f /etc/systemd/system/containerd.service ]; then
    info "fetching containerd.service"
    fetch "https://raw.githubusercontent.com/containerd/containerd/v${CONTAINERD_VERSION}/containerd.service" "${WORKDIR}/containerd.service"
    sudo install -m 644 "${WORKDIR}/containerd.service" /etc/systemd/system/containerd.service
    ok "installed containerd.service"
  else
    ok "containerd.service already present"
  fi

  # systemd cgroup driver with runc - kubelet is configured the same way below,
  # so both sides agree on a single cgroup hierarchy.
  write_file /etc/containerd/config.toml 'version = 3

[plugins."io.containerd.cri.v1.runtime".containerd.runtimes.runc.options]
SystemdCgroup = true'
  local config_changed="$FILE_CHANGED"

  sudo systemctl daemon-reload
  sudo systemctl enable --now containerd
  if [ "$config_changed" -eq 1 ]; then
    sudo systemctl restart containerd
  fi
  sudo systemctl is-active --quiet containerd || die "containerd failed to start (journalctl -u containerd)"
  ok "containerd is running"
}

step_runc() {
  log "runc ${RUNC_VERSION}"

  if command -v runc >/dev/null && runc --version | head -1 | grep -q "${RUNC_VERSION#v}"; then
    ok "runc ${RUNC_VERSION} already installed"
    return
  fi
  fetch "https://github.com/opencontainers/runc/releases/download/${RUNC_VERSION}/runc.${ARCH}" "${WORKDIR}/runc.${ARCH}"
  sudo install -m 755 "${WORKDIR}/runc.${ARCH}" /usr/local/sbin/runc
  ok "installed $(runc --version | head -1)"
}

step_nerdctl() {
  log "nerdctl ${NERDCTL_VERSION}"

  if command -v nerdctl >/dev/null && nerdctl --version | grep -q "${NERDCTL_VERSION}"; then
    ok "nerdctl ${NERDCTL_VERSION} already installed"
  else
    local tarball="nerdctl-${NERDCTL_VERSION}-linux-${ARCH}.tar.gz"
    fetch "https://github.com/containerd/nerdctl/releases/download/v${NERDCTL_VERSION}/${tarball}" "${WORKDIR}/${tarball}"
    tar xzof "${WORKDIR}/${tarball}" -C "${WORKDIR}" nerdctl
    sudo install -m 755 "${WORKDIR}/nerdctl" /usr/local/bin/nerdctl
    ok "installed $(nerdctl --version)"
  fi

  if [ ! -f /etc/bash_completion.d/nerdctl ]; then
    nerdctl completion bash | sudo tee /etc/bash_completion.d/nerdctl >/dev/null
    ok "installed bash completion"
  fi
}

step_cni() {
  log "CNI plugins ${CNI_PLUGINS_VERSION}"

  # /opt/cni/bin is the path both containerd and kubernetes network add-ons
  # look in by convention.
  if [ -x /opt/cni/bin/bridge ]; then
    ok "CNI plugins already installed in /opt/cni/bin"
    return
  fi
  local tarball="cni-plugins-linux-${ARCH}-${CNI_PLUGINS_VERSION}.tgz"
  fetch "https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGINS_VERSION}/${tarball}" "${WORKDIR}/${tarball}"
  sudo mkdir -p /opt/cni/bin
  sudo tar xzofC "${WORKDIR}/${tarball}" /opt/cni/bin
  ok "installed $(ls /opt/cni/bin | wc -l) plugins"
}

step_kubelet() {
  log "kubelet ${KUBE_VERSION}"

  if command -v kubelet >/dev/null && kubelet --version | grep -q "${KUBE_VERSION}"; then
    ok "kubelet ${KUBE_VERSION} already installed"
  else
    fetch "https://dl.k8s.io/${KUBE_VERSION}/bin/linux/${ARCH}/kubelet" "${WORKDIR}/kubelet"
    sudo install -m 755 "${WORKDIR}/kubelet" /usr/local/bin/kubelet
    ok "installed $(kubelet --version)"
  fi

  # The course serves its own unit file; fall back to an equivalent one if that
  # URL has rotated (it carries a ?v= cache-buster that changes per cohort).
  local unit_url="https://labs.iximiuz.com/content/files/courses/kubernetes-the-very-hard-way-0cbfd997/02-worker-node/02-kubelet/__static__/kubelet.service"
  if [ ! -f /etc/systemd/system/kubelet.service ]; then
    if fetch "$unit_url" "${WORKDIR}/kubelet.service" 2>/dev/null; then
      sudo install -m 644 "${WORKDIR}/kubelet.service" /etc/systemd/system/kubelet.service
      ok "installed kubelet.service (from course)"
    else
      warn "course kubelet.service unavailable, using built-in equivalent"
      write_file /etc/systemd/system/kubelet.service '[Unit]
Description=kubelet: The Kubernetes Node Agent
Documentation=https://kubernetes.io/docs/
Wants=network-online.target containerd.service
After=network-online.target containerd.service

[Service]
ExecStart=/usr/local/bin/kubelet --config-dir='"${KUBELET_CONFIG_DIR}"'
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target'
    fi
  else
    ok "kubelet.service already present"
  fi

  # Drop-ins are merged in lexical order by --config-dir.
  local kubelet_changed=0

  # Point kubelet at containerd, and match containerd's cgroup driver.
  write_file "${KUBELET_CONFIG_DIR}/99-cri.conf" 'apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration

containerRuntimeEndpoint: unix:///var/run/containerd/containerd.sock
cgroupDriver: systemd'
  kubelet_changed=$(( kubelet_changed + FILE_CHANGED ))

  # Lab-only: open the kubelet API on :10250 so curl can poke it.
  # NEVER do this on a real cluster.
  write_file "${KUBELET_CONFIG_DIR}/10-auth.conf" 'apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration

# WARNING: lab setup only - do not disable auth in production.
authentication:
  anonymous:
    enabled: true
  webhook:
    enabled: false

authorization:
  mode: AlwaysAllow'
  kubelet_changed=$(( kubelet_changed + FILE_CHANGED ))

  sudo systemctl daemon-reload
  sudo systemctl enable --now kubelet
  if [ "$kubelet_changed" -gt 0 ]; then
    sudo systemctl restart kubelet
  fi
  sudo systemctl is-active --quiet kubelet || die "kubelet failed to start (journalctl -u kubelet)"
  ok "kubelet is running"
}

step_staticpods() {
  log "static Pods"

  write_file "${KUBELET_CONFIG_DIR}/50-static-pods.conf" 'apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration

staticPodPath: '"${STATIC_POD_DIR}"
  local changed="$FILE_CHANGED"

  sudo mkdir -p "${STATIC_POD_DIR}"
  write_file "${STATIC_POD_DIR}/podinfo.yaml" 'apiVersion: v1
kind: Pod
metadata:
  name: podinfo
spec:
  hostNetwork: true
  containers:
    - name: podinfo
      image: ghcr.io/stefanprodan/podinfo:latest
      ports:
        - containerPort: 9898'

  if [ "$changed" -gt 0 ]; then
    sudo systemctl restart kubelet
    ok "kubelet restarted to pick up staticPodPath"
  fi
}

step_verify() {
  log "verify"
  local failed=0

  for svc in containerd kubelet; do
    if sudo systemctl is-active --quiet "$svc"; then
      ok "$svc active"
    else
      warn "$svc NOT active - journalctl -u $svc"
      failed=1
    fi
  done

  info "running a throwaway container through nerdctl..."
  if sudo nerdctl run --rm ghcr.io/stefanprodan/podinfo:latest /home/app/podinfo --version >/dev/null 2>&1; then
    ok "container runtime + CNI working"
  else
    warn "nerdctl run failed - check CNI plugins in /opt/cni/bin"
    failed=1
  fi

  info "waiting for the podinfo static Pod (up to 60s)..."
  local i
  for i in $(seq 1 30); do
    if curl -fsS http://localhost:9898/version >/dev/null 2>&1; then
      ok "static Pod podinfo serving on :9898"
      break
    fi
    sleep 2
    if [ "$i" -eq 30 ]; then
      warn "podinfo never came up - sudo nerdctl ps --namespace k8s.io"
      failed=1
    fi
  done

  if curl -fsSk https://localhost:10250/healthz >/dev/null 2>&1; then
    ok "kubelet API healthy on :10250"
  else
    warn "kubelet /healthz unreachable"
    failed=1
  fi

  printf '\n'
  if [ "$failed" -eq 0 ]; then
    printf '\033[1;32mNode is ready.\033[0m Try:\n'
  else
    printf '\033[1;33mNode is up with warnings.\033[0m Useful commands:\n'
  fi
  cat <<'EOF'
    sudo nerdctl ps --namespace k8s.io           # k8s uses the k8s.io containerd namespace
    sudo ctr namespace ls
    curl -sfk https://localhost:10250/pods | jq '.items[0].metadata'
    curl -s http://localhost:9898 | jq
EOF
  return "$failed"
}

#-----------------------------------------------------------------------------
# Main
#-----------------------------------------------------------------------------
ALL_STEPS=(containerd runc nerdctl cni kubelet staticpods verify)

usage() {
  sed -n '3,17p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

main() {
  case "${1:-}" in
    -h|--help) usage 0 ;;
    --list) printf '%s\n' "${ALL_STEPS[@]}"; exit 0 ;;
  esac

  [ "$(id -u)" -eq 0 ] || sudo -v || die "this script needs sudo"
  command -v curl >/dev/null || die "curl is required"
  mkdir -p "$WORKDIR"

  local steps=()
  if [ "$#" -eq 0 ]; then
    steps=("${ALL_STEPS[@]}")
  else
    steps=("$@")
  fi

  local step
  for step in "${steps[@]}"; do
    case " ${ALL_STEPS[*]} " in
      *" $step "*) "step_${step}" ;;
      *) die "unknown step '$step' (try --list)" ;;
    esac
  done
}

main "$@"
