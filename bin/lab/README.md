# Local lab

Runs Tinkerbell on a [kind](https://kind.sigs.k8s.io/) cluster and simulates bare-metal machines with QEMU, each in its own container on the same Docker network. The machines PXE-boot from smee, boot HookOS, and run Workflows like real hardware. KVM is not required: QEMU uses software emulation (TCG), so it works inside a VM without nested virtualization.

## Requirements

- Docker, with `/dev/net/tun` on the host.
- `kind`, `helm`, `kubectl`, and `go` on `PATH`. If any are missing and `nix-shell` is available, `lab.sh` re-runs itself under `nix-shell -p kind kubernetes-helm kubectl go`.
- Internet access from Docker containers. HookOS pulls the tink-agent and action images from public registries.

## Quick start

```bash
bin/lab/lab.sh up          # kind cluster + Tinkerbell built from this checkout
bin/lab/lab.sh vm vm1 1    # Hardware "vm1" and a UEFI QEMU machine for it
bin/lab/lab.sh smoke vm1   # run the smoke Workflow and check the machine's disk
bin/lab/lab.sh down        # delete the machines and the cluster
```

`up` builds `./cmd/tinkerbell` for the host architecture and loads it into kind as `tink-lab/tinkerbell:dev`. Run `up` again after changing code to rebuild and restart the pod. To use a published image instead, set `TINK_IMAGE=ghcr.io/tinkerbell/tinkerbell:latest`.

Run `bin/lab/lab.sh --help` for all commands.

## How it works

```
Docker network "kind" (172.18.0.0/16, one L2 bridge)
├── tink-lab-control-plane (kind node, 172.18.0.2)
│   ├── tinkerbell pod   hostNetwork: DHCP :67, TFTP :69, HTTP :7080, gRPC :42113
│   └── hookos pod       hostNetwork: nginx :7173 serving vmlinuz/initramfs
└── tink-lab-vm-<name>   container: eth0 ── br0 ── tap0 ── QEMU virtio NIC
```

- Both pods use `hostNetwork`, so smee receives DHCP broadcasts on the kind node's `eth0`, which is the Docker bridge. kube-vip and the chart's macvlan init container are turned off. See `values.yaml`.
- Each machine container moves its `eth0` into a bridge with a tap device, and QEMU's NIC uses the tap. The VM's MAC address is then directly on the kind network.
- `lab.sh vm <name> <n>` gives the machine MAC `52:54:00:1a:b0:<n>` and IP `a.b.100.<n>` on the kind subnet, and creates a v1alpha1 Hardware object with that reservation.
- Machine state lives in `bin/lab/.state/<name>/`: the disk image, OVMF variables, the HookOS kernel console (`ttyS1.log`), and the QEMU monitor socket.

## Watching a machine

| What | How |
|------|-----|
| Firmware and iPXE output | `docker logs -f tink-lab-vm-<name>` |
| HookOS kernel console | `bin/lab/lab.sh console <name>` |
| VGA display | `bin/lab/lab.sh screenshot <name>` prints the path of a PNG |
| iPXE log lines | smee's syslog receiver logs them: `kubectl --context kind-tink-lab -n tinkerbell logs deploy/tinkerbell` |
| Reboot | `bin/lab/lab.sh reset <name>` |

## Timing and limits

- With UEFI, a smoke run takes about two minutes from reboot to `SUCCESS` on an 8-vCPU host, most of it the HookOS boot under TCG.
- BIOS machines (`lab.sh vm <name> <n> bios`) work but are impractical for full runs. smee serves them `undionly.kpxe`, which sends every packet through the NIC's real-mode PXE ROM. Under TCG that downloads at about 60 KB/s, so the 184 MB initramfs takes around 45 minutes. BIOS machines are still useful for testing DHCP, TFTP, and the iPXE script.
- Power control is manual (`lab.sh reset`). There is no BMC emulator yet, so rufio `Machine` and `Job` objects have nothing to talk to.
- Machines are x86_64 only.
