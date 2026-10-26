
output "instance_details" {
  description = "Details of all Ansible lab EC2 instances"

  value = {
    for name, instance in aws_instance.my_instance : name => {
      id         = instance.id
      public_ip  = instance.public_ip
      private_ip = instance.private_ip
      user       = var.instances[name].user
      os_family  = var.instances[name].os_family
    }
  }
}

output "control_node_public_ip" {
  description = "Public IP of the Ansible control node"

  value = aws_instance.my_instance["control-node-ubuntu"].public_ip
}

output "inventory_file" {
  description = "Generated Ansible inventory path"

  value = local_file.ansible_inventory.filename
}

