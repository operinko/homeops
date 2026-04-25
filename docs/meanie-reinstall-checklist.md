---
# Meanie (HP DL360 Gen9) -- Full Proxmox Reinstall Checklist
# Date: _______________

## 1. Pre-flight

- [ ] Verify SOPS age key is available locally
      (SOPS_AGE_KEY_FILE env var, check with: sops -d any-sops-file)
- [ ] Verify Proxmox ISO is downloaded and on USB boot media
- [ ] Confirm remaining cluster health:
      kubectl get nodes
      talosctl -n 192.168.7.22 health (talos2/NUC)
      talosctl -n 192.168.7.23 health (talos3/TrueNAS)
- [ ] Note current Proxmox cluster status:
      pvecm status (run on meanie)
      Record if meanie is part of a cluster


## 2. Verify PBS backups

All LXCs/VMs are backed up to PBS on TrueNAS (off-machine).

- [ ] Check PBS UI: verify recent successful backup for each:
      LXC 102 (mariadb), 104 (bambuddy), 105 (emqx),
      107 (nodered), 109 (hass), 113 (npmplus),
      115 (vaultwarden), 116 (peanut), 117 (sabnzbd2)
      VM 120 (talos1), 122 (talos4), 123 (talos5)
- [ ] If any backup is stale, trigger a manual backup now:
      vzdump <id> --storage pbs --mode snapshot
- [ ] Optional extra safety: mariadb consistency dump
      pct exec 102 -- mysqldump --all-databases > /tmp/mariadb-all.sql
      Copy off-machine

Note: Proxmox host configs (/etc/pve/lxc, /etc/pve/qemu-server,
backup jobs) are cluster-wide. They will sync automatically when
meanie rejoins the cluster. LXC/VM configs restore with PBS backups.


## 3. Kubernetes preparation

- [ ] Verify API VIP is responding BEFORE draining:
      ping 192.168.7.2
      kubectl --server=https://192.168.7.2:6443 get nodes
- [ ] Verify all 3 CP endpoints present:
      kubectl get endpointslices kubernetes
      (should show 192.168.7.21, .22, .23)
- [ ] Cordon meanie Talos nodes:
      kubectl cordon talos1.vaderrp.com
      kubectl cordon talos4.vaderrp.com
      kubectl cordon talos5.vaderrp.com
- [ ] Drain meanie Talos nodes:
      kubectl drain talos1.vaderrp.com --ignore-daemonsets --delete-emptydir-data
      kubectl drain talos4.vaderrp.com --ignore-daemonsets --delete-emptydir-data
      kubectl drain talos5.vaderrp.com --ignore-daemonsets --delete-emptydir-data
- [ ] Verify VIP migrated to talos2 or talos3:
      ping 192.168.7.2 (should respond)
      kubectl get nodes (remaining nodes Ready)
- [ ] Check etcd health (2/3 members must be healthy):
      talosctl -n 192.168.7.22 etcd members
- [ ] Verify workloads rescheduled to remaining nodes:
      kubectl get pods -A | grep -v Running | grep -v Completed


## 4. Proxmox cluster removal

Skip if meanie is standalone (not clustered).

- [ ] On meanie: pvecm status (note cluster membership)
- [ ] On a REMAINING cluster node: pvecm delnode meanie
- [ ] Verify quorum on remaining nodes: pvecm status
      (TrueNAS runs a ProxmoxQuorum VM for this)


## 5. Physical: swap drives

Power off meanie after all backups are confirmed safe.

Current drives (remove all):
  Bay 0: /dev/sda - Samsung 850 EVO 500GB (boot)
  Bay 1: /dev/sdb - Kingston SA400 480GB (ZFS)
  Bay 2: /dev/sdc - Kingston SA400 480GB (ZFS)
  Bay 3: /dev/sdd - Kingston SA400 480GB (ZFS)
  Bay 4: /dev/sde - Samsung 870 QVO 1TB (LVM)
  Bay 5: /dev/sdf - Kingston SA400 120GB (LVM)
  Bay 6-7: empty

- [ ] Power off meanie: shutdown -h now
- [ ] Remove all 6 existing drives from bays
- [ ] Install 8x Samsung PM883 480GB in all 8 SFF bays
- [ ] Note which bay gets the boot drive (bay 0 recommended)
- [ ] Record serial numbers and bay positions:
      Bay 0 (rpool): SN ________________ Rev ________
      Bay 1 (tank):  SN ________________ Rev ________
      Bay 2 (tank):  SN ________________ Rev ________
      Bay 3 (tank):  SN ________________ Rev ________
      Bay 4 (tank):  SN ________________ Rev ________
      Bay 5 (tank):  SN ________________ Rev ________
      Bay 6 (tank):  SN ________________ Rev ________
      Bay 7 (tank):  SN ________________ Rev ________


## 6. Proxmox installation

- [ ] Boot from Proxmox USB installer
- [ ] Select target disk for OS: first PM883 (bay 0)
      Filesystem: ZFS (creates rpool automatically, single disk)
- [ ] Set hostname: meanie.vaderrp.com (or previous hostname)
- [ ] Configure network:
      Use Marvell AQC113CS (ens1, 2.5Gbps) as primary bridge uplink
      HPE 331i 1Gb ports available as fallback/management
      Enable jumbo frames (mtu 9000) on all interfaces
      IP: ________________ (record meanie's management IP)
      Gateway: 192.168.7.1
      DNS: ________________
- [ ] Complete installation, reboot, remove USB
- [ ] Verify web UI accessible: https://<meanie-ip>:8006
- [ ] Verify bridge is using AQC113CS:
      ethtool ens1 (should show Speed: 2500Mb/s)

Note (post-install optimization): Consider setting up 4x 331i as
LACP bond to UDM Pro Max + AQC113CS 2.5G to USW Pro Max 16 PoE as
primary uplink, with active-backup failover between the two. Gives
2.5G burst for single flows, 4G aggregate, and switch redundancy.

Rough OVS config for reference:

  auto eth0
  iface eth0 inet manual
      mtu 9000

  auto eth1
  iface eth1 inet manual
      mtu 9000

  auto eth2
  iface eth2 inet manual
      mtu 9000

  auto eth3
  iface eth3 inet manual
      mtu 9000

  auto ens1
  iface ens1 inet manual
      mtu 9000

  auto bond0
  iface bond0 inet manual
      ovs_bridge vmbr0
      ovs_type OVSBond
      ovs_bonds eth0 eth1 eth2 eth3
      ovs_options bond_mode=balance-tcp lacp=active \
        other_config:lacp-time=fast
      mtu 9000

  auto vmbr0
  iface vmbr0 inet static
      address <ip>/24
      gateway 192.168.7.1
      ovs_type OVSBridge
      ovs_ports bond0 ens1
      mtu 9000

Note: Talos nodes currently configured with mtu 1500 in
talconfig.yaml and node templates (talos1/4/5.yaml.j2).
Update to mtu 9000 to match the jumbo frame bridge.


## 7. ZFS pool creation

- [ ] Identify the 7 remaining PM883 drives:
      lsblk (the non-rpool drives)
      Record device names: /dev/sd_ /dev/sd_ /dev/sd_ ...
- [ ] Create tank pool (RAIDZ1, 7 drives):
      zpool create -o ashift=12 tank raidz1 \
        /dev/disk/by-id/<disk1> \
        /dev/disk/by-id/<disk2> \
        /dev/disk/by-id/<disk3> \
        /dev/disk/by-id/<disk4> \
        /dev/disk/by-id/<disk5> \
        /dev/disk/by-id/<disk6> \
        /dev/disk/by-id/<disk7>
      (use by-id paths, not /dev/sdX)
- [ ] Verify: zpool status tank
- [ ] Add tank as Proxmox storage:
      pvesm add zfspool tank --pool tank --content rootdir,images
- [ ] Optional: set compression
      zfs set compression=lz4 tank


## 8. Restore LXCs

Restore from vzdump backups (adjust paths to backup location).

- [ ] LXC 115 - vaultwarden (32GB)
      pct restore 115 <backup-file> --storage tank
- [ ] LXC 109 - Home Assistant (64GB)
      pct restore 109 <backup-file> --storage tank
- [ ] LXC 102 - mariadb (4GB)
      pct restore 102 <backup-file> --storage tank
- [ ] LXC 107 - nodered (10GB)
      pct restore 107 <backup-file> --storage tank
- [ ] LXC 105 - emqx (10GB)
      pct restore 105 <backup-file> --storage tank
- [ ] LXC 113 - npmplus (30GB)
      pct restore 113 <backup-file> --storage tank
- [ ] LXC 116 - peanut/NUT (7GB)
      pct restore 116 <backup-file> --storage tank
- [ ] LXC 104 - bambuddy
      pct restore 104 <backup-file> --storage tank
- [ ] LXC 117 - sabnzbd2 (increase disk to ~300GB)
      pct restore 117 <backup-file> --storage tank
      pct resize 117 rootfs 300G
- [ ] Start all LXCs and verify each is running:
      pct start <id> for each
- [ ] Verify vaultwarden accessible: https://vaultwarden.vaderrp.com
- [ ] Verify Home Assistant accessible: https://hass.vaderrp.com
- [ ] Verify NUT monitoring working (other hosts depend on this)
- [ ] Verify bambuddy reachable at 192.168.7.12
      (K8s NetworkAttachment depends on this IP)


## 9. Recreate Talos VMs

Create VMs with resources matching previous setup.

VM 120 - talos1 (control plane):
- [ ] Create VM 120, 64GB disk on tank
- [ ] Set NIC MAC to match Talos config or update talconfig.yaml
      Current MAC selector: glob("bc:24:11:*")
      Assigned MAC: ________________
- [ ] Attach Talos ISO or PXE boot

VM 122 - talos4 (worker):
- [ ] Create VM 122, 32GB disk on tank
- [ ] Add second 256GB disk (local-storage for UserVolumeConfig)
- [ ] Set NIC MAC or update talconfig.yaml
      Assigned MAC: ________________

VM 123 - talos5 (worker):
- [ ] Create VM 123, 32GB disk on tank
- [ ] Add second 256GB disk (local-storage for UserVolumeConfig)
- [ ] Set NIC MAC or update talconfig.yaml
      Assigned MAC: ________________


## 10. Talos configuration and cluster rejoin

- [ ] If VM MACs changed, update talos/talconfig.yaml:
      talos1: hardwareAddr for 192.168.7.21
      talos4: hardwareAddr for 192.168.7.24
      talos5: hardwareAddr for 192.168.7.25
      NOTE: talos4 and talos5 currently share the same
      hardwareAddr (bc:24:11:97:b5:eb) -- fix this now
- [ ] Generate Talos configs:
      task talos:generate-config
- [ ] Apply config to talos1 (control plane first):
      task talos:apply-node IP=192.168.7.21 MODE=auto
- [ ] Wait for talos1 to join cluster and etcd:
      talosctl -n 192.168.7.21 health
      talosctl -n 192.168.7.21 etcd members (should show 3)
- [ ] Apply config to talos4:
      task talos:apply-node IP=192.168.7.24 MODE=auto
- [ ] Apply config to talos5:
      task talos:apply-node IP=192.168.7.25 MODE=auto
- [ ] Uncordon all nodes:
      kubectl uncordon talos1.vaderrp.com
      kubectl uncordon talos4.vaderrp.com
      kubectl uncordon talos5.vaderrp.com


## 11. Post-install verification

Kubernetes:
- [ ] All 7 nodes Ready: kubectl get nodes
- [ ] VIP responding: ping 192.168.7.2
- [ ] etcd healthy (3 members): talosctl -n 192.168.7.21 etcd members
- [ ] Pods rescheduling: kubectl get pods -A (no stuck pods)
- [ ] Flux reconciling: flux get ks -A

Services:
- [ ] vaultwarden.vaderrp.com accessible
- [ ] hass.vaderrp.com accessible
- [ ] Bitwarden ESO provider working (depends on vaultwarden)
- [ ] bambuddy reachable at 192.168.7.12 from K8s pods
- [ ] NUT monitoring functional (check UPS status from clients)
- [ ] sabnzbd -- confirm which instance is active (K8s vs LXC 117)
- [ ] mariadb accepting connections
- [ ] nodered flows running
- [ ] emqx broker accepting MQTT connections
- [ ] npmplus proxying correctly

Storage:
- [ ] zpool status tank -- healthy, no degraded vdevs
- [ ] zpool status rpool -- healthy
- [ ] df -h -- adequate free space


## 12. Quick reference

Talos node IPs:
  talos1 (CP):     192.168.7.21
  talos2 (CP):     192.168.7.22  (NUC, not on meanie)
  talos3 (CP):     192.168.7.23  (TrueNAS, not on meanie)
  talos4 (worker): 192.168.7.24
  talos5 (worker): 192.168.7.25
  API VIP:         192.168.7.2
  Cluster endpoint: https://cluster.vaderrp.com:6443

Talos image:
  factory.talos.dev/installer/c0ffd3f955ccbf8853e2905290e152aa377a6c6393b527d90050067986f98d3e

Key dependencies:
  bambuddy K8s -> LXC 104 at 192.168.7.12
  homepage -> hass.vaderrp.com (LXC 109)
  Bitwarden ESO -> vaultwarden.vaderrp.com (LXC 115)
  NUT clients -> 192.168.3.92 (NUT server, verify this IP)

Talos patches (talconfig.yaml):
  Global: machine-files, machine-kubelet, machine-network,
          machine-sysctls, machine-time, nut-config
  Worker: user-data (UserVolumeConfig local-storage)
  Controller: cluster, kubernetes-talos-api-access

NUT config (Talos extension):
  MONITOR 192.168.3.92 1 nutuser <password> secondary

Drive layout:
  rpool: 1x PM883 480GB (single, bay 0)
  tank:  7x PM883 480GB (RAIDZ1, bays 1-7)

PM883 drive batches:
  2x Rev 0 2018.07 (SNs: CZ3906ZT6B, CZ3906ZT67)
  3x Rev 0 2019.02
  2x Rev 0 2019.10
  1x Rev 0 2020.12
