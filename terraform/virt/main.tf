terraform {
 required_version = ">= 0.13"
  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "0.6.2"
    }
  }
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
      ip = cidrhost(var.virt_network_cidr, var.virt_network_router_address)
    }

    dynamic "hosts" {
      for_each = var.virt_network_hosts
      content {
        hostname = "${hosts.value.hostname}.${var.virt_network_dns_suffix}"
        ip = cidrhost(var.virt_network_cidr, hosts.value.ip)
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
              <xsl:value-of select="'${cidrhost(var.virt_network_cidr, var.virt_network_dhcp_endrange)}'" />
            </xsl:attribute>
            <xsl:apply-templates select="@*[not(local-name()='end')]|node()"/>
          </xsl:copy>
        </xsl:template>

      </xsl:stylesheet>
    EOXSLT
  }
}
