#!/usr/bin/env bash
# ==============================================================================
# DISASTER DRILL: TOTAL INTERNET TERMINATION & COMPLETE BROWSER LOCKOUT
# Run with: sudo ./total_net_kill.sh
# ==============================================================================
set -e

if [[ $EUID -ne 0 ]]; then
   echo -e "\033[1;31m[-] Must run as root: sudo ./total_net_kill.sh\033[0m"
   exit 1
fi

TARGET_USER="${SUDO_USER:-$(who | awk '{print $1}' | head -n 1)}"
[[ -z "$TARGET_USER" ]] && TARGET_USER="$USER"
USER_HOME=$(eval echo "~$TARGET_USER")
BACKUP_DIR="/var/network_kill_backup"
mkdir -p "$BACKUP_DIR"

# ------------------------------------------------------------------------------
# 1. PROCESS TERMINATION & PROFILE HARD-LOCK
# ------------------------------------------------------------------------------
echo "[*] Forcefully terminating all browser instances (Native, Snap, Flatpak)..."
killall -9 firefox firefox-bin 2>/dev/null || true
pkill -9 -f "firefox" 2>/dev/null || true
snap stop firefox 2>/dev/null || true
flatpak kill org.mozilla.firefox 2>/dev/null || true

# Lock down all user profile roots with root-owned 000 lockfiles
if [[ -d "$USER_HOME/.mozilla/firefox" ]]; then
    touch "$USER_HOME/.mozilla/firefox/.parentlock"
    find "$USER_HOME/.mozilla/firefox" -maxdepth 2 -type d -name "*.*" -exec touch "{}/.parentlock" \; 2>/dev/null || true
    chmod 000 "$USER_HOME/.mozilla/firefox/.parentlock" 2>/dev/null || true
    chmod 000 "$USER_HOME/.mozilla/firefox"/*/.parentlock 2>/dev/null || true
    chown -R root:root "$USER_HOME/.mozilla/firefox"/**/.parentlock 2>/dev/null || true
fi

# ------------------------------------------------------------------------------
# 2. IDENTIFY INTERFACES & GATEWAY
# ------------------------------------------------------------------------------
PRIMARY_IFACE=$(ip route | grep default | awk '{print $5}' | head -n 1)
[[ -z "$PRIMARY_IFACE" ]] && PRIMARY_IFACE=$(ip -br link | grep -v 'lo' | awk '{print $1}' | head -n 1)
PRIMARY_GW=$(ip route | grep default | awk '{print $3}' | head -n 1)

echo "$PRIMARY_IFACE $PRIMARY_GW" > "$BACKUP_DIR/state.env"

# ------------------------------------------------------------------------------
# 3. MULTI-LAYER NETWORK SABOTAGE
# ------------------------------------------------------------------------------
echo "[*] Deploying multi-tier network breakdown..."

# L2: Static dead MAC for the gateway & ARP suppression
if [[ -n "$PRIMARY_GW" && -n "$PRIMARY_IFACE" ]]; then
    ip neigh replace "$PRIMARY_GW" lladdr 02:00:00:de:ad:01 dev "$PRIMARY_IFACE" nud permanent 2>/dev/null || true
    ip link set dev "$PRIMARY_IFACE" arp off 2>/dev/null || true
fi

# L3: Default route dropped & public DNS blackholed
ip route del default 2>/dev/null || true
ip route add blackhole 1.1.1.1 2>/dev/null || true
ip route add blackhole 8.8.8.8 2>/dev/null || true
ip route add blackhole 9.9.9.9 2>/dev/null || true

# L3/L4: Choke loopback and interface MTU (Path MTU Blackhole)
ip link set dev lo mtu 256
[[ -n "$PRIMARY_IFACE" ]] && ip link set dev "$PRIMARY_IFACE" mtu 552 2>/dev/null || true

# L4: Clamped buffers, starved ports & zeroed transmit queue
[[ -n "$PRIMARY_IFACE" ]] && ip link set dev "$PRIMARY_IFACE" txqueuelen 0 2>/dev/null || true
sysctl -w net.core.rmem_max=2048 >/dev/null
sysctl -w net.core.wmem_max=2048 >/dev/null
sysctl -w net.ipv4.ip_local_port_range="61000 61001" >/dev/null
sysctl -w net.ipv4.tcp_window_scaling=0 >/dev/null

# Netfilter: Silent drops on TCP SYN outbound and all UDP DNS
iptables -A OUTPUT -p tcp --syn -j DROP 2>/dev/null || true
iptables -A OUTPUT -p udp --dport 53 -j DROP 2>/dev/null || true
iptables -A OUTPUT -p tcp --dport 53 -j DROP 2>/dev/null || true

# L7: Point resolv.conf to non-routable blackhole IP and lock it
if [[ -e /etc/resolv.conf ]]; then
    cp -P /etc/resolv.conf "$BACKUP_DIR/resolv.conf.bak" 2>/dev/null || true
    rm -f /etc/resolv.conf
    echo "nameserver 192.0.2.53" > /etc/resolv.conf
    chattr +i /etc/resolv.conf 2>/dev/null || true
fi

# L7: Strip DNS provider from Name Service Switch
if [[ -f /etc/nsswitch.conf ]]; then
    cp /etc/nsswitch.conf "$BACKUP_DIR/nsswitch.conf.bak" 2>/dev/null || true
    sed -i 's/^hosts:.*/hosts:          files/' /etc/nsswitch.conf
fi

# L7: Poison /etc/hosts with loopback redirects
cp /etc/hosts "$BACKUP_DIR/hosts.bak" 2>/dev/null || true
cat << 'EOF' >> /etc/hosts
127.0.0.1  mozilla.org
127.0.0.1  firefox.com
127.0.0.1  google.com
127.0.0.1  archive.ubuntu.com
EOF

# ------------------------------------------------------------------------------
# 4. TRAP RUNTIME ALIASES
# ------------------------------------------------------------------------------
cat << 'EOF' > /etc/profile.d/triage_traps.sh
alias firefox='echo "XPCOMGlueLoad error: libxul.so missing"; false'
alias curl='echo "curl: (7) Failed to connect: Network dropped by peer"; false'
alias ping='echo "ping: socket: Operation not permitted"; false'
EOF

clear
echo -e "\033[1;31m======================================================================\033[0m"
echo -e "\033[1;31m[!] BLACKOUT COMPLETE: HOST NETWORK DESTABILIZED & BROWSER LOCKED     \033[0m"
echo -e "\033[1;31m======================================================================\033[0m"
echo -e "Primary Interface : \033[1;33m$PRIMARY_IFACE\033[0m"
echo -e "Original Gateway  : \033[1;33m$PRIMARY_GW\033[0m\n"
echo -e "Failures deployed: Process kill, parentlock injection, ARP off + poisoning,"
echo -e "blackhole routes, MTU frame drops, buffer exhaustion, port starvation,"
echo -e "iptables SYN drops, DNS blackholing with immutable flags, and nsswitch hijacking.\n"
echo -e "Audit your repairs using your verification commands."