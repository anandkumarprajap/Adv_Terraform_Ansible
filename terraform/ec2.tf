
# --------------------------------------------------
# 1. Create an AWS key pair for SSH access
# --------------------------------------------------
resource "aws_key_pair" "ansible" {
  key_name   = var.key_name
  public_key = file("${path.module}/terra-key-ansible.pub")

  tags = {
    Name      = var.key_name
    ManagedBy = "terraform"
    Project   = "ansible-training"
  }
}

# --------------------------------------------------
# 2. Find the default VPC
# --------------------------------------------------
data "aws_vpc" "default" {
  default = true
}

# --------------------------------------------------
# 3. Find the latest official Ubuntu 24.04 LTS AMI
# --------------------------------------------------
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

# --------------------------------------------------
# 4. Security group for the Ansible lab
# --------------------------------------------------
resource "aws_security_group" "ansible_lab" {
  name        = "ansible-lab-sg"
  description = "Security group for Ansible training"
  vpc_id      = data.aws_vpc.default.id

  # SSH access from the current public IP
  ingress {
    description = "SSH from Terraform host public IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["65.1.134.84/32"]
  }

  # Allow SSH between instances using this security group
  ingress {
    description = "SSH between Ansible lab instances"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    self        = true
  }

  # HTTP
  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTPS
  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Outbound traffic
  egress {
    description = "Allow outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name      = "ansible-lab-sg"
    ManagedBy = "terraform"
    Project   = "ansible-training"
  }
}

# --------------------------------------------------
# 5. Create the control node and three worker nodes
# --------------------------------------------------
resource "aws_instance" "my_instance" {
  for_each = var.instances

  ami                         = data.aws_ami.ubuntu.id
  instance_type               = each.value.instance_type
  key_name                    = aws_key_pair.ansible.key_name
  vpc_security_group_ids      = [aws_security_group.ansible_lab.id]
  associate_public_ip_address = true

  root_block_device {
    volume_size = var.volume_size
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name      = each.key
    OSFamily  = each.value.os_family
    ManagedBy = "terraform"
    Project   = "ansible-training"
  }
}



