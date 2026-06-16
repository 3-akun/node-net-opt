#!/usr/bin/env bash
# node-net-opt v3 — SS / Hy2 / VLESS-Reality 节点网络栈一键优化
# Debian 12 / Ubuntu 22.04 | 1G/2G VPS
set -euo pipefail
umask 022

SYSCTL_CONF="/etc/sysctl.d/99-node-net-opt.conf"
MODULES_CONF="/etc/modules-load.d/99-node-net-opt.conf"
LIMITS_CONF="/etc/security/limits.d/99-node-net-opt.conf"
SYSTEMD_CONF="/etc/systemd/system.conf.d/99-node-net-opt.conf"
STAMP="$(date +%F-%H%M%S)"
NOFILE=524288

RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[0;33m'; CYN='\033[0;36m'; NC='\033[0m'
die(){ echo -e "${RED}[错误]${NC} $*" >&2; exit 1; }
info(){ echo -e "${YEL}[信息]${NC} $*"; }
ok(){ echo -e "${GRN}[完成]${NC} $*"; }
hint(){ echo -e "${CYN}[提示]${NC} $*"; }
warn(){ echo -e "${RED}[警告]${NC} $*"; }

[[ $EUID -eq 0 ]] || die "请用 root 执行：curl -fsSL ... | bash"

detect_virt(){
  local v="unknown"
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    v="$(systemd-detect-virt 2>/dev/null || echo none)"
  fi
  [[ -f /proc/user_beancounters ]] && v="openvz"
  echo "$v"
}

VIRT="$(detect_virt)"
case "$VIRT" in
  none|kvm|qemu|xen|microsoft|vmware)
    info "虚拟化: ${VIRT}（完整虚拟化，sysctl 通常可正常生效）"
    ;;
  lxc|container|docker|podman|openvz|openvz7)
    warn "虚拟化: ${VIRT} — BBR/conntrack/部分 sysctl 可能被宿主机限制，跳过项属正常"
    hint "OpenVZ/LXC 若 BBR 无法切换，只能换 KVM 或接受默认 cubic"
    ;;
  *)
    info "虚拟化: ${VIRT}"
    ;;
esac

LEGACY=(
  /etc/sysctl.d/99-bbr-fq.conf
  /etc/sysctl.d/99-bbr-fq-streaming.conf
  /etc/sysctl.d/99-proxy-streaming-net.conf
  /etc/sysctl.d/99-proxy-file-max.conf
  /etc/modules-load.d/bbr.conf
  /etc/modules-load.d/proxy-net.conf
  /etc/security/limits.d/99-proxy-streaming.conf
)
for f in "${LEGACY[@]}"; do
  [[ -f "$f" ]] || continue
  mv -f "$f" "${f}.removed.${STAMP}"
  info "已移走旧配置: $f"
done

. /etc/os-release 2>/dev/null || true
info "系统: ${PRETTY_NAME:-unknown} | 内核: $(uname -r)"

MEM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
if (( MEM_MB <= 1536 )); then
  TIER="1g"
  RMAX=16777216; TCP_MAX=16777216
  UDP_MEM="8192 16384 32768"
  CT_MAX=98304; FILE_MAX=1048576; TW_BUCKETS=32768
  info "内存 ${MEM_MB}MB → 保守档"
else
  TIER="2g"
  RMAX=33554432; TCP_MAX=33554432
  UDP_MEM="16384 32768 65536"
  CT_MAX=131072; FILE_MAX=2097152; TW_BUCKETS=65536
  info "内存 ${MEM_MB}MB → 标准档"
fi

avail_cc(){ sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true; }
pick_cc(){
  local a; a="$(avail_cc)"
  if [[ "$a" == *bbr2* ]]; then echo bbr2
  elif [[ "$a" == *bbr* ]]; then echo bbr
  else echo ""; fi
}

modprobe tcp_bbr  2>/dev/null || true
modprobe tcp_bbr2 2>/dev/null || true
modprobe nf_conntrack 2>/dev/null || true
CC="$(pick_cc)"
[[ -n "$CC" ]] && info "拥塞算法: ${CC} + fq" || warn "未检测到 BBR（容器/OpenVZ 常见），TCP 保持系统默认"

sanitize(){
  local f
  for f in /etc/sysctl.conf /etc/sysctl.d/*.conf; do
    [[ -f "$f" ]] || continue
    [[ "$f" == "$SYSCTL_CONF" ]] && continue
    grep -qE '^[[:space:]]*(net\.|fs\.file-max=)' "$f" 2>/dev/null || continue
    cp -a "$f" "${f}.bak.${STAMP}"
    sed -i -E \
      '/^[[:space:]]*(net\.core\.(default_qdisc|rmem_max|wmem_max|rmem_default|wmem_default|optmem_max|netdev_max_backlog|somaxconn)|net\.ipv4\.(tcp_congestion_control|tcp_rmem|tcp_wmem|tcp_slow_start_after_idle|tcp_mtu_probing|tcp_fastopen|tcp_max_syn_backlog|tcp_fin_timeout|tcp_keepalive_time|tcp_keepalive_intvl|tcp_keepalive_probes|tcp_tw_reuse|tcp_max_tw_buckets|udp_mem|udp_rmem_min|udp_wmem_min|ip_local_port_range|ip_forward)|net\.ipv6\.conf\.(all|default)\.(forwarding|disable_ipv6)|net\.netfilter\.nf_conntrack_|fs\.file-max=)/s/^[[:space:]]*/# node-net-opt: /' \
      "$f" 2>/dev/null || true
    info "已注释冲突项: $f"
  done
}
sanitize

cat >"$SYSCTL_CONF" <<EOF
# node-net-opt v3 | tier=${TIER} | $(date -Is)
# SS / Hy2 / VLESS-Reality | Debian12/U22.04

# TCP 拥塞 (SS / VLESS-Reality)
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=${CC:-cubic}

# TCP/UDP 缓冲 (Hy2)
net.core.rmem_max=${RMAX}
net.core.wmem_max=${RMAX}
net.core.rmem_default=262144
net.core.wmem_default=262144
net.core.optmem_max=8388608

# TCP 长连接 / 直播
net.ipv4.tcp_rmem=4096 87380 ${TCP_MAX}
net.ipv4.tcp_wmem=4096 65536 ${TCP_MAX}
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.tcp_fin_timeout=30
net.ipv4.tcp_keepalive_time=600
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=5

# TIME-WAIT 出站（落地机高出站）
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_max_tw_buckets=${TW_BUCKETS}

# UDP (Hy2)
net.ipv4.udp_mem=${UDP_MEM}
net.ipv4.udp_rmem_min=8192
net.ipv4.udp_wmem_min=8192

# 队列 / 端口
net.core.netdev_max_backlog=163840
net.core.somaxconn=8192
net.ipv4.ip_local_port_range=1024 65535

# 连接跟踪
net.netfilter.nf_conntrack_max=${CT_MAX}
net.netfilter.nf_conntrack_tcp_timeout_established=7200
net.netfilter.nf_conntrack_udp_timeout=120
net.netfilter.nf_conntrack_udp_timeout_stream=300

# 转发 (WARP / TUN / WireGuard)
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
net.ipv6.conf.default.forwarding=1

# 句柄上限（内核级）
fs.file-max=${FILE_MAX}
EOF

if [[ -z "$CC" ]]; then
  sed -i '/net.core.default_qdisc=fq/d;/net.ipv4.tcp_congestion_control=/d' "$SYSCTL_CONF"
fi

cat >"$MODULES_CONF" <<EOF
tcp_bbr
nf_conntrack
EOF
[[ "$CC" == "bbr2" ]] && echo tcp_bbr2 >>"$MODULES_CONF"

cat >"$LIMITS_CONF" <<EOF
* soft nofile ${NOFILE}
* hard nofile ${NOFILE}
root soft nofile ${NOFILE}
root hard nofile ${NOFILE}
EOF

mkdir -p /etc/systemd/system.conf.d
cat >"$SYSTEMD_CONF" <<EOF
[Manager]
DefaultLimitNOFILE=${NOFILE}
EOF

apply_service_dropin(){
  local svc="$1" dir="/etc/systemd/system/${svc}.service.d"
  systemctl cat "$svc" >/dev/null 2>&1 || return 0
  mkdir -p "$dir"
  cat >"${dir}/99-node-net-opt.conf" <<EOF
[Service]
LimitNOFILE=${NOFILE}
EOF
  info "已写入 systemd drop-in: ${svc}.service"
}

for s in xray xrayr hysteria hysteria-server sing-box s-box shadowsocks-libev ss-server; do
  apply_service_dropin "$s"
done

systemctl daemon-reexec 2>/dev/null || true
systemctl daemon-reload 2>/dev/null || true

apply_line(){
  local line="$1" key val
  [[ "$line" =~ ^[[:space:]]*# ]] && return 0
  [[ "$line" =~ ^[[:space:]]*$ ]] && return 0
  key="${line%%=*}"; val="${line#*=}"
  if sysctl -w "${key}=${val}" >/dev/null 2>&1; then
    :
  else
    hint "跳过: ${key}"
  fi
}
while IFS= read -r line; do apply_line "$line"; done < "$SYSCTL_CONF"
sysctl --system >/dev/null 2>&1 || true

echo
ok "优化完成（可重复执行）"
echo
info "=== TCP ==="
sysctl net.ipv4.tcp_congestion_control 2>/dev/null || echo "  (不可用)"
sysctl net.core.default_qdisc 2>/dev/null || true
sysctl net.ipv4.tcp_slow_start_after_idle 2>/dev/null || true
sysctl net.ipv4.tcp_tw_reuse 2>/dev/null || hint "tcp_tw_reuse 不可用（可忽略）"
sysctl net.ipv4.tcp_max_tw_buckets 2>/dev/null || hint "tcp_max_tw_buckets 不可用（可忽略）"
echo
info "=== UDP / 转发 ==="
sysctl net.ipv4.udp_mem 2>/dev/null || true
sysctl net.ipv4.ip_forward 2>/dev/null || true
sysctl net.ipv6.conf.all.forwarding 2>/dev/null || true
echo
info "=== 并发 ==="
sysctl net.netfilter.nf_conntrack_max 2>/dev/null || hint "conntrack 不可用（容器常见）"
systemctl show --property DefaultLimitNOFILE 2>/dev/null || true
echo
hint "请重启代理: systemctl restart hysteria-server sing-box xray 2>/dev/null"
hint "验证 NOFILE: cat /proc/\$(pidof xray 2>/dev/null || pidof sing-box 2>/dev/null || echo 1)/limits | grep 'Max open files'"
hint "回滚: rm -f $SYSCTL_CONF $MODULES_CONF $LIMITS_CONF $SYSTEMD_CONF /etc/systemd/system/*.service.d/99-node-net-opt.conf && systemctl daemon-reexec && sysctl --system"
