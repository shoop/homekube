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
        export INSTALL_K3S_EXEC="server --cluster-init --tls-san ${local.dns_apiserver} --tls-san ${var.cp_keepalived_api_vip} --node-name ${format(var.cp_hostname_format, count.index + 1)} --cluster-cidr ${var.cni_cluster_cidr} --disable=traefik --disable=servicelb --disable-cloud-controller --disable-network-policy ${var.cni_backend_args} --kube-controller-manager-arg=flex-volume-plugin-dir=/etc/kubernetes/kubelet-plugins/volume/exec"
        %{ else ~}
        export INSTALL_K3S_EXEC="server --server https://${local.dns_apiserver}:6443 --node-name ${format(var.cp_hostname_format, count.index + 1)} --cluster-cidr ${var.cni_cluster_cidr} --disable=traefik --disable=servicelb --disable-cloud-controller --disable-network-policy ${var.cni_backend_args} --kube-controller-manager-arg=flex-volume-plugin-dir=/etc/kubernetes/kubelet-plugins/volume/exec"
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
    verification = "sha512-246b3696df2a4368b7393e4c89c84ec97430c674fef51b6a540ae62e52fff9104c778df4ce7fef476c332041760167ed1a6719a4eb518746b2ff24849cd005f6"
  }
}

# TODO: cache locally, only on first cp
data "ignition_file" "calico_resources" {
  count = var.cp_count
  path = "/etc/kubernetes/calico-install/calico-custom-resources.yaml"
  mode = 420
  source {
    source = "https://docs.projectcalico.org/manifests/custom-resources.yaml"
    verification = "sha512-a5e34853b2d24caced8e8aa72b5eb849cd2a3623f8e9e648e66dadded5d1ff220849d153ce842832b8355ac40f3ba1f677aed6b0efdedf9a41e35ddb82e13563"
  }
}

data "ignition_config" "cp_ignition_config" {
  count = var.cp_count
  systemd = [
    data.ignition_systemd_unit.run_k3s_prereq_installer[count.index].rendered,
    data.ignition_systemd_unit.run_k3s_installer[count.index].rendered,
    data.ignition_systemd_unit.mask_docker[count.index].rendered,
    data.ignition_systemd_unit.mask_zincati[count.index].rendered,
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
}

resource "libvirt_ignition" "cp_vm_ignition_config" {
  count = var.cp_count
  name = "${format(var.cp_hostname_format, count.index + 1)}_ignition_config"
  content = data.ignition_config.cp_ignition_config[count.index].rendered
}

resource "libvirt_volume" "fcos_base_image" {
  name = "fedora_coreos_stable"
  # TODO: generic
  source = "../deps/fcos/fedora-coreos-35.20220116.3.0-qemu.x86_64.qcow2"
}

resource "libvirt_volume" "cp_disk" {
  count = var.cp_count
  name = format(var.cp_hostname_format, count.index + 1)
  base_volume_id = libvirt_volume.fcos_base_image.id
  size = var.cp_disk_gb * 1024 * 1024 * 1024
}

resource "libvirt_domain" "cp_vm" {
  count = var.cp_count
  name = format(var.cp_hostname_format, count.index + 1)
  vcpu = var.cp_vcpu
  memory = var.cp_ram_mb
  disk {
    volume_id = libvirt_volume.cp_disk[count.index].id
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
  coreos_ignition = libvirt_ignition.cp_vm_ignition_config[count.index].id
}

output "cp_ips" {
  value = libvirt_domain.cp_vm[*].*.network_interface.0.addresses[0]
}
