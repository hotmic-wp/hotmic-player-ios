#!/usr/bin/env bash
set -euo pipefail
# Explicitly scoped egress shaping; run only on a dedicated Linux origin NIC.
if [ "$(uname -s)" != Linux ]; then echo 'netem requires Linux; not applied' >&2; exit 1; fi
if [ "$#" -ne 2 ]; then echo 'Usage: sudo netem.sh INTERFACE lan|good-lte|fair-4g|poor|clear|show' >&2; exit 2; fi
iface=$1; profile=$2
command -v tc >/dev/null || { echo 'Missing tc (iproute2)' >&2; exit 1; }
case "$profile" in
  show) tc -s qdisc show dev "$iface"; exit;;
  clear) tc qdisc del dev "$iface" root 2>/dev/null || true; echo "$iface: cleared"; tc qdisc show dev "$iface"; exit;;
  lan) rate=1000mbit; delay=0ms; loss=0%;;
  good-lte) rate=30mbit; delay=50ms; loss=0%;;
  fair-4g) rate=5mbit; delay=100ms; loss=0.5%;;
  poor) rate=1.5mbit; delay=200ms; loss=1%;;
  *) echo "Unknown profile: $profile" >&2; exit 2;;
esac
# Only the response leg is shaped, so its delay adds the full target RTT.
# For a symmetric router topology, split this delay equally across both legs.
tc qdisc replace dev "$iface" root handle 1: tbf rate "$rate" burst 64kb latency 400ms
tc qdisc replace dev "$iface" parent 1:1 handle 10: netem delay "$delay" loss "$loss"
echo "$iface: $profile (rate=$rate one-way-delay=$delay loss=$loss)"
tc -s qdisc show dev "$iface"
