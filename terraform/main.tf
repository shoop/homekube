terraform {
 required_version = ">= 0.13"
  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "0.6.2"
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
  default = "kube.home"
}

variable "virt_network_cidr" {
  type = string
  default = "192.168.10.0/24"
}

variable "virt_network_dhcp_endrange" {
  type = string
  default = "192.168.10.199"
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

variable "cp_keepalived_vip" {
  type = string
  default = "192.168.10.200"
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
    "ssh-rsa AAAAB3NzaC1yc2EAAAABJQAAAQEAnwm807zV8im1zCfY8XJQN/SzldUKCRvIQaR7Lm5WKPvs6wYRgR6l29hcx5U1JGmjQ1hBvfJ9+XPNWAAMrIdWLfAoel1SrlYK91Uc9uylMly7GWhw5BCI5cYqGXzr3GOYVx1mQ9PVH4GQM3USVWpCF9hXBGV4f3q6ezmwBkQeW9zwGmaMpbIQDd7deEGiQ3HhnM4ccCMbzz8NG1Ca9HFANyWVqUL37GCEoQDDQm80uoGxMbWT6UyWFPuXkqrtc5q05XvLhPbCMq4kN846I+ZfKPv8K6SchuVo8xcUOGQkZb1WAvPiRJzTBNknX3gnfH/28GVqWbfXXfCdneuUeJ6u5Q== stijn@kzp.sandcat.nl"
  ]
  description = "The authorized key(s) for the administrative user(s) of the cluster"
}

locals {
  dns_apiserver = "apiserver.${var.virt_network_dns_suffix}"
}

resource "libvirt_network" "kubenet" {
  name = var.virt_network_name
  mode = var.virt_network_mode
  bridge = var.virt_network_bridge_name
  domain = var.virt_network_dns_suffix
  addresses = [ var.virt_network_cidr ]
  autostart = true

  dns {
    enabled = true

    hosts {
      hostname = "router.${var.virt_network_dns_suffix}"
      ip = "192.168.10.1"
    }

    hosts {
      hostname = local.dns_apiserver
      ip = var.cp_keepalived_vip
    }

    dynamic "hosts" {
      for_each = range(var.cp_count)
      content {
        hostname = "${format(var.cp_hostname_format, hosts.value + 1)}.${var.virt_network_dns_suffix}"
        ip = "192.168.10.${format("%d", 200 + hosts.value + 1)}"
      }
    }
  }

  dhcp {
    enabled = true
  }

  xml {
    # Set DHCP end range using XSLT for now
    # https://github.com/dmacvicar/terraform-provider-libvirt/issues/794
    xslt = <<-EOXSLT
      <?xml version="1.0" ?>
      <xsl:stylesheet version="1.0"
                      xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        <xsl:output omit-xml-declaration="yes" indent="yes"/>
        <xsl:template match="node()|@*">
          <xsl:copy>
            <xsl:apply-templates select="node()|@*"/>
          </xsl:copy>
        </xsl:template>

        <xsl:template match="/network/ip/dhcp/range">
          <xsl:copy>
            <xsl:attribute name="end">
              <xsl:value-of select="'${var.virt_network_dhcp_endrange}'" />
            </xsl:attribute>
            <xsl:apply-templates select="@*[not(local-name()='end')]|node()"/>
          </xsl:copy>
        </xsl:template>

      </xsl:stylesheet>
    EOXSLT
  }
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
        name: keepalived-ingress-vip
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
            vipAddressCidr: "${var.cp_keepalived_vip}/${var.cp_keepalived_subnet_size}"
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
        rpm-ostree install https://github.com/k3s-io/k3s-selinux/releases/download/v0.3.stable.0/k3s-selinux-0.3-0.el7.noarch.rpm
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
        export INSTALL_K3S_EXEC="server --cluster-init --tls-san ${local.dns_apiserver} --tls-san ${var.cp_keepalived_vip} --node-name ${format(var.cp_hostname_format, count.index + 1)} --cluster-cidr ${var.cni_cluster_cidr} --disable=traefik ${var.cni_backend_args} --kube-controller-manager-arg=flex-volume-plugin-dir=/etc/kubernetes/kubelet-plugins/volume/exec"
        %{ else ~}
        export INSTALL_K3S_EXEC="server --server https://${local.dns_apiserver}:6443 --node-name ${format(var.cp_hostname_format, count.index + 1)} --cluster-cidr ${var.cni_cluster_cidr} --disable=traefik ${var.cni_backend_args} --kube-controller-manager-arg=flex-volume-plugin-dir=/etc/kubernetes/kubelet-plugins/volume/exec"
        while curl --connect-timeout 0.1 -s https://${local.dns_apiserver}:6443 ; [ $? -eq 28 ] ; do echo "${local.dns_apiserver}:6443 not up, sleeping..."; sleep 5; done
        echo "${local.dns_apiserver}:6443 up. Avoiding etcd join race..."
        # Sleep a while to avoid 2 etcd learners joining at the same time
        sleep ${(count.index - 1) * 25}
        %{ endif ~}

        sed -i -e 's/cidr: .*/cidr: 10.42.0.0\/16/' -e '/ipPools:/i \ \ \ \ containerIPForwarding: Enabled' -e '/calicoNetwork:/i \ \ flexVolumePath: /etc/kubernetes/kubelet-plugins/volume/exec' /etc/kubernetes/calico-install/calico-custom-resources.yaml
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

# TODO: only on first cp
data "ignition_file" "calico_operator" {
  count = var.cp_count
  path = "/etc/kubernetes/calico-install/tigera-operator.yaml"
  mode = 420
  source {
    source = "https://docs.projectcalico.org/manifests/tigera-operator.yaml"
    verification = "sha512-99d8880d925dd3fc89520e13dff36c97d677a82968bfa4037f2af653be1da18c1ce689f1a9cb08280ea96b43605d7b05d110ea70a809d2c3dcc3f04fdd712268"
  }
}

# TODO: only on first cp
data "ignition_file" "calico_resources" {
  count = var.cp_count
  path = "/etc/kubernetes/calico-install/calico-custom-resources.yaml"
  mode = 420
  source {
    source = "https://docs.projectcalico.org/manifests/custom-resources.yaml"
    verification = "sha512-d01791d8648467126c735581f17a00cfd508102dba09b9c2b0a408423c097557d844f9184a7bb5cc119040567bbe435950630189db309847a1282f59ddecaae7"
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
  source = "../images/fedora-coreos-33.20210301.3.1-qemu.x86_64.qcow2"
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
    network_id = libvirt_network.kubenet.id
    hostname = format(var.cp_hostname_format, count.index + 1)
    addresses = [ "192.168.10.${format("%d", 200 + count.index + 1)}" ]
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
