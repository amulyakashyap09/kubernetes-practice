#!/usr/bin/env bash
#
# Rebuild the "Kubernetes the Very Hard Way" node from scratch.
# Chapter 06: containerd -> runc -> nerdctl -> CNI plugins -> kubelet -> static
# Pods -> crictl -> kubeletctl -> etcd (with TLS).
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
# Steps: containerd runc nerdctl cni kubelet staticpods crictl kubeletctl
#        etcd verify

set -euo pipefail

#-----------------------------------------------------------------------------
# Versions - bump these as the course moves on.
#-----------------------------------------------------------------------------
CONTAINERD_VERSION="${CONTAINERD_VERSION:-2.2.1}"   # no leading v
RUNC_VERSION="${RUNC_VERSION:-v1.4.0}"
NERDCTL_VERSION="${NERDCTL_VERSION:-2.2.1}"         # no leading v
CNI_PLUGINS_VERSION="${CNI_PLUGINS_VERSION:-v1.9.0}"
KUBE_VERSION="${KUBE_VERSION:-v1.34.0}"
CRICTL_VERSION="${CRICTL_VERSION:-v1.34.0}"
KUBELETCTL_VERSION="${KUBELETCTL_VERSION:-v1.13}"
ETCD_VERSION="${ETCD_VERSION:-v3.6.4}"

WORKDIR="${WORKDIR:-/tmp/k8s-hard-way}"
STATIC_POD_DIR=/etc/kubernetes/manifests
KUBELET_CONFIG_DIR=/var/lib/kubelet/config.d
CRI_SOCK=unix:///var/run/containerd/containerd.sock
ETCD_PKI_DIR=/etc/etcd/pki

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

# Append a block to a file exactly once, keyed off a marker string that is
# already present after the first append.
append_once() {  # append_once <file> <marker> <content> [sudo]
  local path="$1" marker="$2" content="$3" as_root="${4:-}"
  if [ -f "$path" ] && grep -qF "$marker" "$path"; then
    ok "$path already configured"
    FILE_CHANGED=0
    return 0
  fi
  if [ -n "$as_root" ]; then
    printf '\n%s\n' "$content" | sudo tee -a "$path" >/dev/null
  else
    printf '\n%s\n' "$content" | tee -a "$path" >/dev/null
  fi
  ok "appended to $path"
  FILE_CHANGED=1
  return 0
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
  write_file "${KUBELET_CONFIG_DIR}/70-authnz.conf" 'apiVersion: kubelet.config.k8s.io/v1beta1
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

step_crictl() {
  log "crictl ${CRICTL_VERSION}"

  # crictl talks the CRI gRPC API directly - the same API kubelet uses, so it
  # sees pod sandboxes and containers the way kubelet does (unlike nerdctl,
  # which only sees containerd).
  if command -v crictl >/dev/null && crictl --version | grep -q "${CRICTL_VERSION}"; then
    ok "crictl ${CRICTL_VERSION} already installed"
  else
    local tarball="crictl-${CRICTL_VERSION}-linux-${ARCH}.tar.gz"
    fetch "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/${tarball}" "${WORKDIR}/${tarball}"
    sudo tar xzof "${WORKDIR}/${tarball}" -C /usr/local/bin
    ok "installed $(crictl --version)"
  fi

  # Same containerd socket kubelet is pointed at.
  write_file /etc/crictl.yaml "runtime-endpoint: ${CRI_SOCK}
image-endpoint: ${CRI_SOCK}"
}

step_kubeletctl() {
  log "kubeletctl ${KUBELETCTL_VERSION}"

  # kubeletctl drives a single node's kubelet API (:10250) - not the cluster
  # API server the way kubectl does.
  if command -v kubeletctl >/dev/null; then
    ok "kubeletctl already installed"
    return
  fi
  fetch "https://github.com/cyberark/kubeletctl/releases/download/${KUBELETCTL_VERSION}/kubeletctl_linux_${ARCH}" "${WORKDIR}/kubeletctl_linux_${ARCH}"
  sudo install -m 755 "${WORKDIR}/kubeletctl_linux_${ARCH}" /usr/local/bin/kubeletctl
  ok "installed kubeletctl"
}

# Generate the etcd CA, server and client certificates (only if missing).
etcd_certs() {
  if sudo test -f "${ETCD_PKI_DIR}/client.crt"; then
    ok "etcd certificates already present in ${ETCD_PKI_DIR}"
    return 1
  fi

  local pki="${WORKDIR}/etcd-pki"
  rm -rf "$pki" && mkdir -p "$pki"
  info "generating CA, server and client certificates"

  openssl genrsa -out "${pki}/ca.key" 4096 2>/dev/null
  openssl req -x509 -new -nodes -key "${pki}/ca.key" -out "${pki}/ca.crt" \
    -subj "/CN=etcd" -sha256 -days 3650 2>/dev/null

  # SANs: localhost, this host's name, loopback, and every non-loopback IPv4
  # on the box (each as its own IP.N entry).
  {
    cat <<EOF
[ req ]
default_bits       = 2048
distinguished_name = req_distinguished_name
req_extensions     = req_ext
prompt             = no

[ req_distinguished_name ]
CN = server

[ req_ext ]
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = localhost
DNS.2 = $(hostname)
IP.1  = 127.0.0.1
IP.2  = ::1
EOF
    local n=3 ip
    for ip in $(ip -o -4 addr show scope global | awk '{split($4,a,"/"); print a[1]}'); do
      printf 'IP.%d  = %s\n' "$n" "$ip"
      n=$((n + 1))
    done
  } > "${pki}/server.cnf"

  openssl genrsa -out "${pki}/server.key" 2048 2>/dev/null
  openssl req -new -key "${pki}/server.key" -out "${pki}/server.csr" -config "${pki}/server.cnf" 2>/dev/null
  openssl x509 -req -in "${pki}/server.csr" -out "${pki}/server.crt" \
    -CA "${pki}/ca.crt" -CAkey "${pki}/ca.key" -CAcreateserial \
    -days 365 -extfile "${pki}/server.cnf" -extensions req_ext 2>/dev/null

  openssl genrsa -out "${pki}/client.key" 2048 2>/dev/null
  openssl req -new -key "${pki}/client.key" -out "${pki}/client.csr" -subj "/CN=etcd/O=etcd" 2>/dev/null
  openssl x509 -req -in "${pki}/client.csr" -out "${pki}/client.crt" \
    -CA "${pki}/ca.crt" -CAkey "${pki}/ca.key" -CAcreateserial -days 365 2>/dev/null

  sudo mkdir -p "$ETCD_PKI_DIR"
  sudo cp "${pki}"/{ca.crt,ca.key,server.crt,server.key,server.cnf,client.crt,client.key} "$ETCD_PKI_DIR/"
  sudo chown -R etcd:etcd "$ETCD_PKI_DIR"
  # Lab-only: lets the unprivileged lab user authenticate with etcd.
  sudo chmod 644 "${ETCD_PKI_DIR}/client.key"
  ok "certificates written to ${ETCD_PKI_DIR}"
  return 0
}

step_etcd() {
  log "etcd ${ETCD_VERSION}"

  if command -v etcd >/dev/null && etcd --version | grep -q "${ETCD_VERSION#v}"; then
    ok "etcd ${ETCD_VERSION} already installed"
  else
    local dir="etcd-${ETCD_VERSION}-linux-${ARCH}"
    fetch "https://github.com/etcd-io/etcd/releases/download/${ETCD_VERSION}/${dir}.tar.gz" "${WORKDIR}/${dir}.tar.gz"
    tar xzof "${WORKDIR}/${dir}.tar.gz" -C "${WORKDIR}"
    sudo install -m 755 "${WORKDIR}/${dir}"/etcd "${WORKDIR}/${dir}"/etcdctl "${WORKDIR}/${dir}"/etcdutl /usr/local/bin
    ok "installed $(etcd --version | head -1)"
  fi

  if [ ! -f /etc/bash_completion.d/etcdctl ]; then
    etcdctl completion bash | sudo tee /etc/bash_completion.d/etcdctl >/dev/null
    ok "installed etcdctl bash completion"
  fi

  # Dedicated service account - etcd should never run as root.
  if id etcd >/dev/null 2>&1; then
    ok "etcd user already exists"
  else
    sudo adduser --system --group --disabled-login --disabled-password \
      --home /var/lib/etcd etcd >/dev/null
    ok "created etcd system user"
  fi
  sudo mkdir -p /var/lib/etcd
  sudo chown etcd:etcd /var/lib/etcd

  local etcd_changed=0

  # Certificates and TLS config go in BEFORE the first start, so etcd is never
  # bootstrapped under a different name/URL and then renamed.
  if etcd_certs; then
    etcd_changed=1
  fi

  append_once /etc/default/etcd "ETCD_TRUSTED_CA_FILE" "ETCD_LISTEN_CLIENT_URLS=https://0.0.0.0:2379

ETCD_CLIENT_CERT_AUTH=true
ETCD_CERT_FILE=${ETCD_PKI_DIR}/server.crt
ETCD_KEY_FILE=${ETCD_PKI_DIR}/server.key
ETCD_TRUSTED_CA_FILE=${ETCD_PKI_DIR}/ca.crt

ETCD_NAME=$(hostname)
ETCD_ADVERTISE_CLIENT_URLS=https://$(hostname):2379" sudo
  etcd_changed=$(( etcd_changed + FILE_CHANGED ))

  # The course serves its own unit file; fall back to an equivalent one.
  local unit_url="https://labs.iximiuz.com/content/files/courses/kubernetes-the-very-hard-way-0cbfd997/03-control-plane/01-etcd/__static__/etcd.service"
  if [ ! -f /etc/systemd/system/etcd.service ]; then
    if fetch "$unit_url" "${WORKDIR}/etcd.service" 2>/dev/null; then
      sudo install -m 644 "${WORKDIR}/etcd.service" /etc/systemd/system/etcd.service
      ok "installed etcd.service (from course)"
    else
      warn "course etcd.service unavailable, using built-in equivalent"
      write_file /etc/systemd/system/etcd.service '[Unit]
Description=etcd - distributed key-value store
Documentation=https://etcd.io/docs/
Wants=network-online.target
After=network-online.target

[Service]
User=etcd
Group=etcd
Type=notify
WorkingDirectory=/var/lib/etcd
EnvironmentFile=-/etc/default/etcd
Environment=ETCD_DATA_DIR=/var/lib/etcd/data
ExecStart=/usr/local/bin/etcd
Restart=always
RestartSec=5
LimitNOFILE=40000

[Install]
WantedBy=multi-user.target'
    fi
    etcd_changed=1
  else
    ok "etcd.service already present"
  fi

  sudo systemctl daemon-reload
  sudo systemctl enable --now etcd
  if [ "$etcd_changed" -gt 0 ]; then
    sudo systemctl restart etcd
  fi
  sudo systemctl is-active --quiet etcd || die "etcd failed to start (journalctl -u etcd)"
  ok "etcd is running"

  # Point etcdctl at the TLS endpoint for future logins.
  local etcdctl_env="export ETCDCTL_CACERT=${ETCD_PKI_DIR}/ca.crt
export ETCDCTL_CERT=${ETCD_PKI_DIR}/client.crt
export ETCDCTL_KEY=${ETCD_PKI_DIR}/client.key
export ETCDCTL_ENDPOINTS=https://127.0.0.1:2379"
  local rc
  for rc in "$HOME/.bashrc" "$HOME/.profile"; do
    [ -f "$rc" ] || touch "$rc"
    append_once "$rc" "ETCDCTL_ENDPOINTS" "$etcdctl_env"
  done
  info "run 'exec bash --login' (or re-open the shell) to pick up ETCDCTL_* vars"
}

step_verify() {
  log "verify"
  local failed=0

  for svc in containerd kubelet etcd; do
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

  if command -v crictl >/dev/null; then
    if sudo crictl pods >/dev/null 2>&1; then
      ok "crictl talking to the CRI endpoint ($(sudo crictl pods -q 2>/dev/null | wc -l | tr -d ' ') sandbox(es))"
    else
      warn "crictl cannot reach ${CRI_SOCK} - check /etc/crictl.yaml"
      failed=1
    fi
  fi

  if command -v etcdctl >/dev/null; then
    if ETCDCTL_CACERT="${ETCD_PKI_DIR}/ca.crt" ETCDCTL_CERT="${ETCD_PKI_DIR}/client.crt" \
       ETCDCTL_KEY="${ETCD_PKI_DIR}/client.key" ETCDCTL_ENDPOINTS=https://127.0.0.1:2379 \
       etcdctl endpoint health >/dev/null 2>&1; then
      ok "etcd healthy over mTLS on :2379"
    else
      warn "etcdctl endpoint health failed - journalctl -u etcd"
      failed=1
    fi
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

    sudo crictl pods                             # CRI view: pod sandboxes
    sudo crictl ps -a                            # CRI view: containers
    kubeletctl pods                              # kubelet API view
    kubeletctl configz | jq                      # merged kubelet config

    bash --login -c "etcdctl endpoint health"    # etcd over mTLS
    bash --login -c "etcdctl get --prefix / --keys-only"
EOF
  return "$failed"
}

#-----------------------------------------------------------------------------
# Main
#-----------------------------------------------------------------------------
ALL_STEPS=(containerd runc nerdctl cni kubelet staticpods crictl kubeletctl etcd verify)

usage() {
  sed -n '3,19p' "$0" | sed 's/^# \{0,1\}//'
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
