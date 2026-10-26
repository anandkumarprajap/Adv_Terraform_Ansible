
locals {
  inventory_content = <<-EOT
[control]
control-node-ubuntu ansible_host=${aws_instance.my_instance["control-node-ubuntu"].public_ip} ansible_user=ubuntu ansible_ssh_private_key_file=${abspath(var.ssh_key_path)}

[workers]
worker-ubuntu ansible_host=${aws_instance.my_instance["worker-ubuntu"].public_ip} ansible_user=ubuntu ansible_ssh_private_key_file=${abspath(var.ssh_key_path)}
worker-redhat ansible_host=${aws_instance.my_instance["worker-redhat"].public_ip} ansible_user=ubuntu ansible_ssh_private_key_file=${abspath(var.ssh_key_path)}
worker-amazon ansible_host=${aws_instance.my_instance["worker-amazon"].public_ip} ansible_user=ubuntu ansible_ssh_private_key_file=${abspath(var.ssh_key_path)}

[all:vars]
ansible_python_interpreter=/usr/bin/python3
EOT
}

resource "local_file" "ansible_inventory" {
  content         = local.inventory_content
  filename        = "${path.module}/../inventories/dev/hosts.ini"
  file_permission = "0600"
}

resource "local_file" "bootstrap_inventory" {
  content         = local.inventory_content
  filename        = "${path.module}/../inventories/dev/bootstrap.ini"
  file_permission = "0600"
}

