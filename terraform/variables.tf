
variable "aws_region" {
  description = "AWS region for the Ansible lab"
  type        = string
  default     = "us-west-2"
}

variable "instance_type" {
  description = "Default EC2 instance type"
  type        = string
  default     = "t3.micro"
}

variable "key_name" {
  description = "AWS EC2 SSH key pair name"
  type        = string
  default     = "terra-key-ansible"
}

variable "volume_size" {
  description = "Root volume size in GB"
  type        = number
  default     = 10
}

variable "ssh_key_path" {
  description = "Private SSH key path on the Terraform host"
  type        = string
  default     = "./terra-key-ansible"
}

variable "instances" {
  description = "EC2 nodes for the Ansible lab"

  type = map(object({
    user          = string
    os_family     = string
    instance_type = string
  }))

  default = {
    control-node-ubuntu = {
      user          = "ubuntu"
      os_family     = "ubuntu"
      instance_type = "t3.micro"
    }

    worker-ubuntu = {
      user          = "ubuntu"
      os_family     = "ubuntu"
      instance_type = "t3.micro"
    }

    worker-redhat = {
      user          = "ubuntu"
      os_family     = "ubuntu"
      instance_type = "t3.micro"
    }

    worker-amazon = {
      user          = "ubuntu"
      os_family     = "ubuntu"
      instance_type = "t3.micro"
    }
  }
}

