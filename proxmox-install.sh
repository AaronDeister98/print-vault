#!/usr/bin/env bash
# Print Vault — Proxmox host installer
# Run ON THE PROXMOX HOST:
# bash <(curl -fsSL https://raw.githubusercontent.com/AaronDeister98/print-vault/main/proxmox-install.sh)
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
VMID="200"
HOSTNAME="print-vault"
STORAGE="local-lvm"
DISK_SIZE="10"
MEMORY="2048"
CORES="2"
BRIDGE="vmbr0"
REPO="https://github.com/AaronDeister98/print-vault"
APP_PORT="5173"
IP_CONFIG="dhcp"   # overridden to "x.x.x.x/xx" if static chosen
GATEWAY=""

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[print-vault]${NC} $*"; }
die()   { echo -e "${RED}[error]${NC}   $*" >&2; exit 1; }
step()  { echo -e "\n${CYAN}── $* ${NC}"; }

# ── Sanity checks ─────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && die "Run as root on the Proxmox host."
command -v pct      &>/dev/null || die "pct not found — run this on a Proxmox VE host."
command -v whiptail &>/dev/null || die "whiptail not found — apt install whiptail"

# ── Helpers ───────────────────────────────────────────────────────────────────
get_storages() {
  pvesm status --content rootdir 2>/dev/null | awk 'NR>1 {print $1, $1}' || echo "local-lvm local-lvm"
}

get_bridges() {
  ip link show | awk -F': ' '/^[0-9]+: vmbr/{print $2, $2}' || echo "vmbr0 vmbr0"
}

get_next_vmid() {
  local id=200
  while pct status "$id" &>/dev/null 2>&1; do ((id++)); done
  echo "$id"
}

# Get gateway for a specific bridge
get_bridge_gw() {
  local bridge=$1
  # Try to get gateway from bridge IP config or routing table
  ip route show | grep -m1 "dev ${bridge}" | awk '{print $3}' || \
  ip route | awk '/^default/{print $3; exit}'
}

# Query DNS for hostname to get pre-assigned IP
get_dns_ip() {
  local hostname=$1
  # Try to resolve hostname and return IP with /24 CIDR (can be modified by user)
  getent hosts "$hostname" 2>/dev/null | awk '{print $1 "/24"}' || echo ""
}

# Reverse DNS lookup to get hostname from IP
get_reverse_dns() {
  local ip=$1
  # Try to reverse resolve IP to hostname
  getent hosts "$ip" 2>/dev/null | awk '{print $2}' | head -1 || echo ""
}

VMID=$(get_next_vmid)

# ── Install mode selection ────────────────────────────────────────────────────
MODE=$(whiptail --title "Print Vault Installer" \
  --menu "\nWelcome to the Print Vault LXC installer.\nChoose install mode:" \
  15 58 2 \
  "1" "Simple   (use defaults, no questions)" \
  "2" "Advanced (configure each option)" \
  3>&1 1>&2 2>&3) || exit 0

# ── Advanced config ───────────────────────────────────────────────────────────
if [[ "$MODE" == "2" ]]; then

  # VMID
  VMID=$(whiptail --title "Print Vault — Advanced Setup" \
    --inputbox "Container ID (next free: $(get_next_vmid)):" \
    8 52 "$VMID" 3>&1 1>&2 2>&3) || exit 0
  [[ "$VMID" =~ ^[0-9]+$ ]] || die "VMID must be a number."

  # Hostname
  HOSTNAME=$(whiptail --title "Print Vault — Advanced Setup" \
    --inputbox "Hostname:" \
    8 52 "$HOSTNAME" 3>&1 1>&2 2>&3) || exit 0

  # Storage
  STORAGE=$(whiptail --title "Print Vault — Advanced Setup" \
    --menu "Root filesystem storage:" \
    15 58 6 $(get_storages) \
    3>&1 1>&2 2>&3) || exit 0

  # Disk size
  DISK_SIZE=$(whiptail --title "Print Vault — Advanced Setup" \
    --inputbox "Disk size (GB):" \
    8 52 "$DISK_SIZE" 3>&1 1>&2 2>&3) || exit 0

  # Memory
  MEMORY=$(whiptail --title "Print Vault — Advanced Setup" \
    --inputbox "RAM (MB):" \
    8 52 "$MEMORY" 3>&1 1>&2 2>&3) || exit 0

  # Cores
  CORES=$(whiptail --title "Print Vault — Advanced Setup" \
    --inputbox "CPU cores:" \
    8 52 "$CORES" 3>&1 1>&2 2>&3) || exit 0

  # Bridge
  BRIDGE=$(whiptail --title "Print Vault — Advanced Setup" \
    --menu "Network bridge:" \
    15 58 6 $(get_bridges) \
    3>&1 1>&2 2>&3) || exit 0

  # IP mode
  IP_MODE=$(whiptail --title "Print Vault — Advanced Setup" \
    --menu "IP configuration:" \
    12 52 2 \
    "dhcp"   "DHCP (automatic)" \
    "static" "Static IP" \
    3>&1 1>&2 2>&3) || exit 0

  if [[ "$IP_MODE" == "static" ]]; then
    DNS_IP=$(get_dns_ip "$HOSTNAME")
    EXT_HOST=""
    if [[ -n "$DNS_IP" ]]; then
      info "Found DNS entry for $HOSTNAME: $DNS_IP"
      # Extract just the IP part (without /24)
      DNS_IP_ONLY="${DNS_IP%%/*}"
      # Try reverse DNS lookup to get hostname
      EXT_HOST=$(get_reverse_dns "$DNS_IP_ONLY")
      if [[ -n "$EXT_HOST" ]]; then
        info "Found reverse DNS entry: $EXT_HOST"
      fi
    fi
    
    STATIC_IP=$(whiptail --title "Print Vault — Advanced Setup" \
      --inputbox "Static IP address with CIDR:\n(e.g. 192.168.1.50/24)" \
      9 52 "$DNS_IP" 3>&1 1>&2 2>&3) || exit 0

    # Validate basic CIDR format
    [[ "$STATIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]] || \
      die "Invalid IP format. Use CIDR notation, e.g. 192.168.1.50/24"

    GATEWAY=$(whiptail --title "Print Vault — Advanced Setup" \
      --inputbox "Gateway IP:" \
      8 52 "$(get_bridge_gw "$BRIDGE")" 3>&1 1>&2 2>&3) || exit 0

    [[ "$GATEWAY" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
      die "Invalid gateway format."

    IP_CONFIG="$STATIC_IP"
  fi

  # App port
  APP_PORT=$(whiptail --title "Print Vault — Advanced Setup" \
    --inputbox "App port:" \
    8 52 "$APP_PORT" 3>&1 1>&2 2>&3) || exit 0

  # External hostname/domain
  EXT_HOST=$(whiptail --title "Print Vault — Advanced Setup" \
    --inputbox "External hostname/domain (for accessing via HTTPS/proxy):\n(leave blank if accessing via IP only)" \
    9 52 "$EXT_HOST" 3>&1 1>&2 2>&3) || exit 0

fi

# ── Build display string for confirm screen ───────────────────────────────────
if [[ "$IP_CONFIG" == "dhcp" ]]; then
  IP_DISPLAY="DHCP"
else
  IP_DISPLAY="${IP_CONFIG} via ${GATEWAY}"
fi

ALLOWED_HOSTS_DISPLAY="${HOSTNAME}"
if [[ -n "$EXT_HOST" ]]; then
  ALLOWED_HOSTS_DISPLAY="${ALLOWED_HOSTS_DISPLAY}, ${EXT_HOST}"
fi

# ── Confirm ───────────────────────────────────────────────────────────────────
whiptail --title "Print Vault — Confirm" --yesno \
"Ready to create LXC with these settings:

  Container ID : $VMID
  Hostname     : $HOSTNAME
  Storage      : $STORAGE
  Disk         : ${DISK_SIZE}GB
  Memory       : ${MEMORY}MB
  Cores        : $CORES
  Bridge       : $BRIDGE
  IP           : $IP_DISPLAY
  App port     : $APP_PORT
  Allowed hosts: $ALLOWED_HOSTS_DISPLAY

Proceed?" 22 52 || exit 0

# ── Validate VMID is free ─────────────────────────────────────────────────────
if pct status "$VMID" &>/dev/null; then
  die "VMID $VMID already exists. Choose a different ID."
fi

# ── Download Debian 12 template ───────────────────────────────────────────────
step "Fetching Debian 12 LXC template"
pveam update
TEMPLATE=$(pveam available --section system | awk '/debian-12/' | sort -r | head -1 | awk '{print $2}')
[[ -z "$TEMPLATE" ]] && die "No Debian 12 template found. Run: pveam update"

TEMPLATE_STORAGE="local"
if ! pveam list "$TEMPLATE_STORAGE" | grep -q "$TEMPLATE"; then
  info "Downloading $TEMPLATE..."
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
else
  info "Template already present: $TEMPLATE"
fi

# ── Build net0 string ─────────────────────────────────────────────────────────
if [[ "$IP_CONFIG" == "dhcp" ]]; then
  NET0="name=eth0,bridge=${BRIDGE},ip=dhcp"
else
  NET0="name=eth0,bridge=${BRIDGE},ip=${IP_CONFIG},gw=${GATEWAY}"
fi

# ── Create LXC ────────────────────────────────────────────────────────────────
step "Creating LXC $VMID ($HOSTNAME)"
pct create "$VMID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
  --hostname "$HOSTNAME" \
  --storage "$STORAGE" \
  --rootfs "${STORAGE}:${DISK_SIZE}" \
  --memory "$MEMORY" \
  --cores "$CORES" \
  --net0 "$NET0" \
  --ostype debian \
  --unprivileged 1 \
  --features nesting=1 \
  --start 1 \
  --onboot 1

info "Waiting for LXC to boot..."
sleep 5

# ── Helper: exec inside LXC ───────────────────────────────────────────────────
lxc() { pct exec "$VMID" -- bash -c "$*"; }

# Wait for network
info "Waiting for network..."
for i in $(seq 1 20); do
  lxc "ping -c1 -W2 8.8.8.8" &>/dev/null && break
  sleep 3
  [[ $i -eq 20 ]] && die "No network after 60s. Check bridge/DHCP/gateway."
done

# ── Fix locale warnings ───────────────────────────────────────────────────────
lxc "echo 'en_US.UTF-8 UTF-8' >> /etc/locale.gen && locale-gen" &>/dev/null || true

# ── System deps ───────────────────────────────────────────────────────────────
step "Installing system dependencies"
lxc "DEBIAN_FRONTEND=noninteractive apt-get update -qq && \
     DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl git ca-certificates gnupg"

# ── Install Docker ─────────────────────────────────────────────────────────────
step "Installing Docker"
lxc "curl -fsSL https://get.docker.com -o get-docker.sh && sh get-docker.sh"

info "Docker: $(lxc 'docker --version')"

# ── Enable Docker ──────────────────────────────────────────────────────────────
step "Configuring Docker"
lxc "systemctl enable --now docker"
lxc "usermod -aG docker root" || true

# ── Generate secrets ──────────────────────────────────────────────────────────
DB_PASS=$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 24)
SECRET_KEY=$(openssl rand -base64 50 | tr -d "=+/" | cut -c1-50)

# Get container IP for APP_HOST if using DHCP
if [[ "$IP_CONFIG" == "dhcp" ]]; then
  APP_HOST=$(pct exec "$VMID" -- hostname -I | awk '{print $1}')
else
  APP_HOST="${IP_CONFIG%%/*}"
fi

# ── App setup ──────────────────────────────────────────────────────────────────
step "Setting up Print Vault application"
lxc "mkdir -p /opt/print-vault/data/{postgres,media}"

# ── Clone repository ──────────────────────────────────────────────────────────
lxc "git clone '${REPO}' /opt/print-vault/app"

# ── Create .env file ──────────────────────────────────────────────────────────
step "Creating environment configuration"

# Build ALLOWED_HOSTS list
ALLOWED_HOSTS_LIST="${APP_HOST},localhost,127.0.0.1"
if [[ -n "$EXT_HOST" ]]; then
  ALLOWED_HOSTS_LIST="${ALLOWED_HOSTS_LIST},${EXT_HOST}"
fi

pct exec "$VMID" -- bash -c "cat > /opt/print-vault/app/.env <<'EOF'
DJANGO_SECRET_KEY='${SECRET_KEY}'
DJANGO_DEBUG='False'
POSTGRES_USER='postgres'
POSTGRES_PASSWORD='${DB_PASS}'
APP_HOST='${APP_HOST}'
ALLOWED_HOSTS='${ALLOWED_HOSTS_LIST}'
APP_PORT='${APP_PORT}'
EOF"

lxc "chmod 600 /opt/print-vault/app/.env"

# ── Start services with docker-compose ─────────────────────────────────────────
step "Starting Print Vault services"
lxc "cd /opt/print-vault/app && docker compose up -d"

# Wait for services to be ready
info "Waiting for services to initialize..."
for i in $(seq 1 30); do
  if lxc "curl -sf http://localhost:8000/api/ > /dev/null 2>&1" &>/dev/null; then
    break
  fi
  sleep 2
  [[ $i -eq 30 ]] && print_warning "Services may still be initializing..."
done

# ── Resolve final IP ──────────────────────────────────────────────────────────
LXC_IP=$(pct exec "$VMID" -- hostname -I | awk '{print $1}')

# ── Done ──────────────────────────────────────────────────────────────────────
whiptail --title "Print Vault — Installation Complete!" --msgbox \
"Print Vault is up and running!

  LXC ID   : $VMID
  App URL  : http://${LXC_IP}:${APP_PORT}
  DB pass  : ${DB_PASS}
             (saved in LXC at /opt/print-vault/app/.env)

Useful commands:
  Shell    : pct enter $VMID
  Logs     : pct exec $VMID -- docker compose -f /opt/print-vault/app/docker-compose.yml logs -f
  Restart  : pct exec $VMID -- docker compose -f /opt/print-vault/app/docker-compose.yml restart
  Stop     : pct exec $VMID -- docker compose -f /opt/print-vault/app/docker-compose.yml down
  Update   : pct exec $VMID -- bash -c \\
             'cd /opt/print-vault/app && git pull && docker compose up -d'" \
22 62

echo -e "\n${GREEN}Done!${NC} Print Vault running at ${YELLOW}http://${LXC_IP}:${APP_PORT}${NC}\n"
