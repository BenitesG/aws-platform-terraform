locals {
  # Achata (servidor x disco) em uma coleção única para o for_each dos volumes e
  # attachments. A chave composta "HOSTNAME:device_name" garante unicidade mesmo
  # quando um servidor tem 2 discos.
  data_disks = merge([
    for host, cfg in var.servers : {
      for disk in cfg.data_disks :
      "${host}:${disk.device_name}" => {
        host        = host
        size        = disk.size
        device_name = disk.device_name
        volume_type = disk.volume_type
      }
    }
  ]...)
}
