variable "virt_network_name" {
  type = string
  default = "kubenet"
}

variable "virt_network_mode" {
  type = string
  default = "nat"

  validation {
    condition = contains(["nat", "none", "route", "bridge"], var.virt_network_mode)
    error_message = "Valid values for virt_network_mode: nat (default), none, route, bridge."
  }
}

variable "virt_network_bridge_name" {
  type = string
  default = null
}

variable "virt_network_dns_suffix" {
  type = string
  default = ".local"
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
  default = 254
}

variable "virt_network_hosts" {
  type = list(object({
    hostname: string,
    ip: number
  }))
  default = []
}
