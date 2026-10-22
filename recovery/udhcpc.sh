#!/bin/sh
# busybox udhcpc 的默认租约处理脚本（精简版）
# $1 = deconfig|bound|renew|leasefail|nak
[ -z "$1" ] && exit 1

case "$1" in
  deconfig)
    ip addr flush dev "$interface" 2>/dev/null
    ip link set "$interface" up 2>/dev/null
    ;;
  bound|renew)
    ip addr flush dev "$interface" 2>/dev/null
    ip addr add "${ip:-0.0.0.0}/${mask:-24}" dev "$interface" 2>/dev/null
    [ -n "${router:-}" ] && ip route add default via "${router%% *}" dev "$interface" 2>/dev/null
    : > /etc/resolv.conf 2>/dev/null
    for d in $dns; do echo "nameserver $d" >> /etc/resolv.conf; done
    ;;
  leasefail|nak)
    ;;
esac
exit 0
