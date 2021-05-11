output "network_id" {
  description = "Network ID for VM creation"
  value = libvirt_network.kubenet.id
}
