terraform {
 required_version = ">= 0.13"
  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "0.6.14"
    }
    ignition = {
      source = "community-terraform-providers/ignition"
      version = "2.1.2"
    }
  }
}

provider "libvirt" {
  uri = "qemu:///system"
}

variable "virt_network_name" {
  type = string
  default = "kubenet"
}

variable "virt_network_mode" {
  type = string
  default = "route"
}

variable "virt_network_bridge_name" {
  type = string
  default = "virbr1"
}

variable "virt_network_dns_suffix" {
  type = string
  default = "svcvm.kzp.home.arpa"
}

variable "virt_network_cidr" {
  type = string
  default = "192.168.110.0/24"
}

variable "virt_network_router_address" {
  type = number
  default = 1
}

variable "virt_network_dhcp_endrange" {
  type = number
  default = 199
}

# --flannel-backend=vxlan (default)
#    Does not work for some reason, TBD
# --flannel-backend=host-gw
#    Works but requires extra routing setup I do not want
# --flannel-backend=none --disable-network-policy
#    Post-setup install Calico for network policy so disable
#    builtin flannel and builtin network policy
variable "cni_backend_args" {
  type = string
  default = "--flannel-backend=none --disable-network-policy"
}

variable "cni_cluster_cidr" {
  type = string
  default = "10.42.0.0/16"
}

variable "cp_count" {
  type = number
  default = 3
  description = "Number of control plane VMs to instantiate"
}

variable "cp_hostname_format" {
  type = string
  default = "cp%02d"
}

variable "cp_interface_name" {
  type = string
  default = "ens3"
  description = "Interface name inside the control plane VM"
}

variable "cp_vcpu" {
  type = number
  default = 2
  description = "The amount of virtual CPUs for the control plane VM"
}

variable "cp_ram_mb" {
  type = number
  default = 2048
  description = "The amount of virtual memory in MB for the control plane VM"
}

variable "cp_disk_gb" {
  type = number
  default = 20
  description = "The amount of storage in GB to allocate for the control plane VM"
}

variable "cp_data_disk_gb" {
  type = number
  default = 20
  description = "The amount of storage in GB to allocate for the data disk of the control plane VM"
}

variable "cp_keepalived_api_vip" {
  type = string
  default = "192.168.110.230"
  description = "The virtual IP that keepalived will assign to an accessible control plane node"
}

variable "cp_keepalived_subnet_size" {
  type = string
  default = "24"
  description = "The subnet mask size for the virtual IP for keepalived"
}

variable "admin_ssh_authorized_keys" {
  type = list(string)
  default = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINIlfYnkJiscuElW4rqbEcvh+u7wsnYBpiUfD9C/yekn stijn@kzp.sandcat.nl"
  ]
  description = "The authorized key(s) for the administrative user(s) of the cluster"
}

locals {
  dns_apiserver = "apiserver.${var.virt_network_dns_suffix}"

  hosts = concat([ { hostname: "apiserver", ip: 230 } ],
    [for cnt in range(var.cp_count) : {
      hostname: format(var.cp_hostname_format, cnt + 1),
      ip: 230 + cnt + 1
    }])
}

module "virt" {
  source = "./virt"

  virt_network_name = var.virt_network_name
  virt_network_mode = var.virt_network_mode
  virt_network_bridge_name = var.virt_network_bridge_name
  virt_network_dns_suffix = var.virt_network_dns_suffix
  virt_network_cidr = var.virt_network_cidr
  virt_network_router_address = var.virt_network_router_address
  virt_network_dhcp_endrange = var.virt_network_dhcp_endrange
  virt_network_hosts = local.hosts
}

data "ignition_systemd_unit" "run_k3s_prereq_installer" {
  count = var.cp_count
  name = "run-k3s-prereq-installer.service"
  enabled = true
  content = <<-EOT
    [Unit]
    After=network-online.target
    Wants=network-online.target
    Before=systemd-user-sessions.service
    OnFailure=emergency.target
    OnFailureJobMode=replace-irreversibly
    ConditionPathExists=!/var/lib/k3s-prereq-installed
    [Service]
    RemainAfterExit=yes
    Type=oneshot
    ExecStart=/usr/local/bin/run-k3s-prereq-installer
    ExecStartPost=/usr/bin/touch /var/lib/k3s-prereq-installed
    ExecStartPost=/usr/bin/systemctl --no-block reboot
    StandardOutput=kmsg+console
    StandardError=kmsg+console
    [Install]
    WantedBy=multi-user.target  
  EOT
}

data "ignition_systemd_unit" "run_k3s_installer" {
  count = var.cp_count
  name = "run-k3s-installer.service"
  enabled = true
  content = <<-EOT
    [Unit]
    After=network-online.target
    Wants=network-online.target
    Before=systemd-user-sessions.service
    OnFailure=emergency.target
    OnFailureJobMode=replace-irreversibly
    ConditionPathExists=/var/lib/k3s-prereq-installed
    ConditionPathExists=!/var/lib/k3s-installed
    [Service]
    RemainAfterExit=yes
    Type=oneshot
    ExecStart=/usr/local/bin/run-k3s-installer
    ExecStartPost=/usr/bin/touch /var/lib/k3s-installed
    StandardOutput=kmsg+console
    StandardError=kmsg+console
    [Install]
    WantedBy=multi-user.target  
  EOT
}

# Mask docker to avoid it inserting iptables chains in the middle.
data "ignition_systemd_unit" "mask_docker" {
  count = var.cp_count
  name = "docker.service"
  mask = true
  enabled = false
}

# Mask zincati for now as we cannot control staging of new image
# and rpm-ostree install defaults to the new image
data "ignition_systemd_unit" "mask_zincati" {
  count = var.cp_count
  name = "zincati.service"
  mask = true
  enabled = false
}

data "ignition_file" "etc_hostname" {
  count = var.cp_count
  path = "/etc/hostname"
  mode = 420
  content {
    content = "${format(var.cp_hostname_format, count.index + 1)}.${var.virt_network_dns_suffix}"
  }
}

data "ignition_file" "silence_audit_conf" {
  count = var.cp_count
  path = "/etc/sysctl.d/20-silence-audit.conf"
  mode = 420
  content {
    content = <<-EOT
      # Raise console message logging level from DEBUG (7) to WARNING (4)
      # to hide audit messages from the interactive console
      kernel.printk=4
    EOT
  }
}

# TODO: change this to fleet_lock once we can confirm that it will run at cluster init
data "ignition_file" "zincati_update_strategy" {
  count = var.cp_count
  path = "/etc/zincati/config.d/90-update-strategy.toml"
  mode = 420
  content {
    content = <<-EOT
      [updates]
      strategy = "periodic"

      [[updates.periodic.window]]
      days = [ "Mon" ]
      start_time = "04:00"
      length_minutes = 60
    EOT
  }
}

data "ignition_file" "k3s_manifest_keepalived_api_vip_yaml" {
  count = var.cp_count
  path = "/var/lib/rancher/k3s/server/manifests/keepalived-api-vip.yaml"
  mode = 420
  content {
    content = <<-EOT
      apiVersion: helm.cattle.io/v1
      kind: HelmChart
      metadata:
        name: keepalived-api-vip
        namespace: kube-system
      spec:
        chart: keepalived-ingress-vip
        version: v0.1.6
        repo: https://janeczku.github.io/helm-charts/
        targetNamespace: kube-system
        valuesContent: |-
          keepalived:
            vrrpInterfaceName: ${var.cp_interface_name}
            vipInterfaceName: ${var.cp_interface_name}
            vipAddressCidr: "${var.cp_keepalived_api_vip}/${var.cp_keepalived_subnet_size}"
            checkServiceUrl: https://127.0.0.1:6443/healthz
            checkKubelet: false
            checkKubeApi: false
          kind: Daemonset
          pod:
            nodeSelector:
              node-role.kubernetes.io/master: "true"  
    EOT
  }
}

data "ignition_file" "cp_run_k3s_prereq_installer" {
  count = var.cp_count
  path = "/usr/local/bin/run-k3s-prereq-installer"
  mode = 493
  content {
    content = <<-EOT
      #!/usr/bin/env sh
      main() {
        rpm-ostree install https://github.com/k3s-io/k3s-selinux/releases/download/v0.5.stable.1/k3s-selinux-0.5-1.el8.noarch.rpm
        return 0
      }
      main    
    EOT
  }
}

data "ignition_file" "cp_run_k3s_installer" {
  count = var.cp_count
  path = "/usr/local/bin/run-k3s-installer"
  mode = 493
  content {
    content = <<-EOT
      #!/usr/bin/env sh
      main() {
        export K3S_KUBECONFIG_MODE="644"
        export K3S_TOKEN="very_secret"
        %{ if count.index == 0 ~}
        export INSTALL_K3S_EXEC="server --cluster-init --tls-san ${local.dns_apiserver} --tls-san ${var.cp_keepalived_api_vip} --node-name ${format(var.cp_hostname_format, count.index + 1)} --cluster-cidr ${var.cni_cluster_cidr} --disable=traefik --disable=servicelb --disable-cloud-controller ${var.cni_backend_args} --kube-controller-manager-arg=flex-volume-plugin-dir=/etc/kubernetes/kubelet-plugins/volume/exec"
        %{ else ~}
        export INSTALL_K3S_EXEC="server --server https://${local.dns_apiserver}:6443 --node-name ${format(var.cp_hostname_format, count.index + 1)} --cluster-cidr ${var.cni_cluster_cidr} --disable=traefik --disable=servicelb --disable-cloud-controller ${var.cni_backend_args} --kube-controller-manager-arg=flex-volume-plugin-dir=/etc/kubernetes/kubelet-plugins/volume/exec"
        while curl --connect-timeout 0.1 -s https://${local.dns_apiserver}:6443 ; [ $? -eq 28 ] ; do echo "${local.dns_apiserver}:6443 not up, sleeping..."; sleep 5; done
        echo "${local.dns_apiserver}:6443 up. Avoiding etcd join race..."
        # Sleep a while to avoid 2 etcd learners joining at the same time
        sleep ${(count.index - 1) * 25}
        %{ endif ~}

        sed -i -e 's#cidr: .*#cidr: ${var.cni_cluster_cidr}#' -e '/ipPools:/i \ \ \ \ containerIPForwarding: Enabled' -e '/calicoNetwork:/i \ \ flexVolumePath: /etc/kubernetes/kubelet-plugins/volume/exec' /etc/kubernetes/calico-install/calico-custom-resources.yaml
        %{ if count.index == 0 ~}
        cp /etc/kubernetes/calico-install/tigera-operator.yaml /var/lib/rancher/k3s/server/manifests/00-tigera-operator.yaml
        cp /etc/kubernetes/calico-install/calico-custom-resources.yaml /var/lib/rancher/k3s/server/manifests/99-calico-custom-resources.yaml
        %{ endif ~}

        echo "Starting k3s install..."
        curl -sfL https://get.k3s.io | sh -
        return 0
      }
      main
    EOT
  }
}

data "ignition_user" "cp_core" {
  name = "core"
  ssh_authorized_keys = var.admin_ssh_authorized_keys
}

# TODO: cache locally, only on first cp
data "ignition_file" "calico_operator" {
  count = var.cp_count
  path = "/etc/kubernetes/calico-install/tigera-operator.yaml"
  mode = 420
  source {
    source = "https://docs.projectcalico.org/manifests/tigera-operator.yaml"
    verification = "sha512-51c9089d9ef9f2eb08395de592739052499a151b02d514099966d55cb833d386f7a4f7ee1b56f9ad5a0697614a1a91fce5f6d93550bc8549cd06a871c7cafe2e"
  }
}

# TODO: cache locally, only on first cp
data "ignition_file" "calico_resources" {
  count = var.cp_count
  path = "/etc/kubernetes/calico-install/calico-custom-resources.yaml"
  mode = 420
  source {
    source = "https://docs.projectcalico.org/manifests/custom-resources.yaml"
    verification = "sha512-b2545c4015853b438c48d7af1c92de28c3a97e206305a2216732d434c282d1f233a3c9cb5df855fa8448b40d32600ead099ebf881b9d591f03cafc908e5f151c"
  }
}

data "ignition_disk" "cp_raid_member_1" {
  count = var.cp_count
  device = "/dev/vdb"
  wipe_table = true
  partition {
    label = "data1.1"
    type_guid = "A19D880F-05FC-4D3B-A006-743F0F84911E"
  }
}

data "ignition_disk" "cp_raid_member_2" {
  count = var.cp_count
  device = "/dev/vdc"
  wipe_table = true
  partition {
    label = "data1.2"
    type_guid = "A19D880F-05FC-4D3B-A006-743F0F84911E"
  }
}

data "ignition_raid" "cp_data" {
  count = var.cp_count
  name = "data"
  level = "raid1"
  devices = [
    "/dev/disk/by-partlabel/data1.1",
    "/dev/disk/by-partlabel/data1.2"
  ]
}

data "ignition_filesystem" "cp_var_lib_longhorn" {
  count = var.cp_count
  path = "/var/lib/longhorn"
  device = "/dev/disk/by-id/md-name-any:data"
  format = "xfs"
  label = "longhorn"
  wipe_filesystem = true
}

data "ignition_systemd_unit" "mount_var_lib_longhorn" {
  count = var.cp_count
  name = "var-lib-longhorn.mount"
  content = <<-EOT
    [Unit]
    Description=Longhorn data directory

    [Mount]
    What=/dev/disk/by-id/md-name-any:data
    Where=/var/lib/longhorn
    Type=xfs

    [Install]
    WantedBy=multi-user.target
  EOT
}

# Enable iscsid for longhorn
data "ignition_systemd_unit" "enable_iscsid" {
  count = var.cp_count
  name = "iscsid.service"
  enabled = true
}

data "ignition_config" "cp_ignition_config" {
  count = var.cp_count
  systemd = [
    data.ignition_systemd_unit.run_k3s_prereq_installer[count.index].rendered,
    data.ignition_systemd_unit.run_k3s_installer[count.index].rendered,
    data.ignition_systemd_unit.mask_docker[count.index].rendered,
    data.ignition_systemd_unit.mask_zincati[count.index].rendered,
    data.ignition_systemd_unit.enable_iscsid[count.index].rendered,
    data.ignition_systemd_unit.mount_var_lib_longhorn[count.index].rendered,
  ]
  files = [
    data.ignition_file.etc_hostname[count.index].rendered,
    data.ignition_file.silence_audit_conf[count.index].rendered,
    data.ignition_file.k3s_manifest_keepalived_api_vip_yaml[count.index].rendered,
    data.ignition_file.cp_run_k3s_prereq_installer[count.index].rendered,
    data.ignition_file.cp_run_k3s_installer[count.index].rendered,
    data.ignition_file.zincati_update_strategy[count.index].rendered,
    data.ignition_file.calico_operator[count.index].rendered,
    data.ignition_file.calico_resources[count.index].rendered,
  ]
  users = [
    data.ignition_user.cp_core.rendered,
  ]
  disks = [
    data.ignition_disk.cp_raid_member_1[count.index].rendered,
    data.ignition_disk.cp_raid_member_2[count.index].rendered
  ]
  arrays = [
    data.ignition_raid.cp_data[count.index].rendered,
  ]
  filesystems = [
    data.ignition_filesystem.cp_var_lib_longhorn[count.index].rendered
  ]
}

#resource "libvirt_ignition" "cp_vm_ignition_config" {
#  count = var.cp_count
#  name = "${format(var.cp_hostname_format, count.index + 1)}_ignition_config"
#  content = data.ignition_config.cp_ignition_config[count.index].rendered
#}

#resource "libvirt_volume" "fcos_base_image" {
#  name = "fedora_coreos_stable"
#  # TODO: generic
#  source = "../deps/fcos/fedora-coreos-35.20220116.3.0-qemu.x86_64.qcow2"
#}

resource "local_file" "cp_vm_ignition_config_file" {
  count = var.cp_count
  filename = "ipxe/192.168.110.${format("%d", 230 + count.index + 1)}_ignition_config"
  content = data.ignition_config.cp_ignition_config[count.index].rendered
}

resource "libvirt_volume" "cp_disk" {
  count = var.cp_count
  name = format(var.cp_hostname_format, count.index + 1)
  #base_volume_id = libvirt_volume.fcos_base_image.id
  size = var.cp_disk_gb * 1024 * 1024 * 1024
}

resource "libvirt_volume" "data_disk_1" {
  count = var.cp_count
  name = format("%s_data_1", format(var.cp_hostname_format, count.index + 1))
  size = var.cp_data_disk_gb * 1024 * 1024 * 1024
}

resource "libvirt_volume" "data_disk_2" {
  count = var.cp_count
  name = format("%s_data_2", format(var.cp_hostname_format, count.index + 1))
  size = var.cp_data_disk_gb * 1024 * 1024 * 1024
}

resource "libvirt_domain" "cp_vm" {
  count = var.cp_count
  name = format(var.cp_hostname_format, count.index + 1)
  vcpu = var.cp_vcpu
  memory = var.cp_ram_mb
  disk {
    volume_id = libvirt_volume.cp_disk[count.index].id
  }
  disk {
    volume_id = libvirt_volume.data_disk_1[count.index].id
  }
  disk {
    volume_id = libvirt_volume.data_disk_2[count.index].id
  }
  network_interface {
    network_id = module.virt.network_id
    hostname = format(var.cp_hostname_format, count.index + 1)
    addresses = [ "192.168.110.${format("%d", 230 + count.index + 1)}" ]
    wait_for_lease = true
  }
  graphics {
    listen_type = "none"
  }
  console {
    type = "pty"
    target_port = "0"
  }
  boot_device {
    dev = [ "hd", "network" ]
  }
  #coreos_ignition = libvirt_ignition.cp_vm_ignition_config[count.index].id

  # Enable BIOS serial console
  xml {
    xslt = <<EOL
      <?xml version="1.0" ?>
      <xsl:stylesheet version="1.0"
          xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
          <!-- Identity template -->
          <xsl:template match="@* | node()">
              <xsl:copy>
                  <xsl:apply-templates select="@* | node()"/>
              </xsl:copy>
          </xsl:template>
          <!-- Override for target element -->
          <xsl:template match="os">
              <xsl:copy>
                  <xsl:apply-templates select="@* | node()"/>
                  <bios useserial="yes"/>
              </xsl:copy>
          </xsl:template>
      </xsl:stylesheet>
    EOL
  }
}

output "cp_ips" {
  value = libvirt_domain.cp_vm[*].*.network_interface.0.addresses[0]
}
