#!/bin/sh
# Fake bare-metal machine: a TCG QEMU VM whose NIC is bridged onto the
# container's eth0, so the VM sits directly on the Docker (kind) L2 network.
set -eu

MAC="${MAC:-52:54:00:12:34:01}"
FIRMWARE="${FIRMWARE:-bios}" # bios | uefi
MEMORY="${MEMORY:-4096}"
CPUS="${CPUS:-4}"
DISK_SIZE="${DISK_SIZE:-10G}"
OUT=/out

mkdir -p "$OUT"

# Hand eth0 over to a bridge and attach the VM's tap to it.
ip link add br0 type bridge
ip addr flush dev eth0
ip link set eth0 master br0
ip tuntap add tap0 mode tap
ip link set tap0 master br0
ip link set br0 up
ip link set tap0 up

[ -f "$OUT/disk.qcow2" ] || qemu-img create -f qcow2 "$OUT/disk.qcow2" "$DISK_SIZE"

set -- \
  -machine q35 -accel tcg,thread=multi -cpu max -smp "$CPUS" -m "$MEMORY" \
  -netdev tap,id=n0,ifname=tap0,script=no,downscript=no \
  -device virtio-net-pci,netdev=n0,mac="$MAC",bootindex=1 \
  -drive file="$OUT/disk.qcow2",if=none,id=d0 -device virtio-blk-pci,drive=d0,bootindex=2 \
  -display none -vnc :0 \
  -serial stdio -serial file:"$OUT/ttyS1.log" \
  -monitor unix:"$OUT/monitor.sock",server,nowait

if [ "$FIRMWARE" = "uefi" ]; then
  [ -f "$OUT/OVMF_VARS.fd" ] || cp /usr/share/OVMF/OVMF_VARS.fd "$OUT/OVMF_VARS.fd"
  set -- "$@" \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE.fd \
    -drive if=pflash,format=raw,file="$OUT/OVMF_VARS.fd"
else
  # Mirror SeaBIOS output (and option ROMs) to serial.
  set -- "$@" -fw_cfg name=etc/sercon-port,string=0x3f8
fi

echo "starting VM mac=$MAC firmware=$FIRMWARE mem=${MEMORY}M cpus=$CPUS"
exec qemu-system-x86_64 "$@"
