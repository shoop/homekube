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

variable "virt_network_router_address" {
  type = number
  default = 1
}

variable "virt_network_dhcp_endrange" {
  type = number
  default = 199
}

variable "virt_network_hosts" {
  type = list(object({
    hostname: string,
    ip: number
  }))
  default = []
}

