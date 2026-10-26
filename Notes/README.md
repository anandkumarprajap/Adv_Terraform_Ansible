# Terraform + Ansible AWS Lab: 4 EC2 Instances

**Goal:** From your local computer, use Terraform to create four EC2
instances:

1.  `master-node` --- Ubuntu, runs Ansible
2.  `ubuntu-node` --- Ubuntu worker
3.  `redhat-node` --- Red Hat Enterprise Linux worker
4.  `amazon-node` --- Amazon Linux worker

Then use Ansible from `master-node` to manage the three worker nodes.

> **Important security notes** - Never commit private keys, AWS secret
> keys, `.tfstate`, or `.tfvars` files to Git. - Prefer IAM
> roles/instance profiles for AWS access from EC2 instead of storing
> long-lived IAM access keys on the master. - For a lab, use narrowly
> scoped IAM permissions. Avoid attaching `AdministratorAccess` or
> giving full EC2/S3/DynamoDB access unless a specific task truly
> requires it. - Restrict SSH (port 22) to **your current public IP**,
> not `0.0.0.0/0`. - Copying a private key to the master works for a lab
> but increases risk. The safer alternative is to generate an Ansible
> key on the master and install its public key on the workers. This
> guide shows the requested SCP method and explains the safer option.

## 0. Architecture and prerequisites

``` text
Your local computer
  ├── Terraform + AWS CLI
  ├── terra-key-ansible.pem (private key; keep private)
  └── Terraform files
          |
          | terraform init / validate / plan / apply
          v
AWS VPC (default VPC in selected region)
  ├── master-node (Ubuntu; public IP; Ansible)
  ├── ubuntu-node (Ubuntu; worker)
  ├── redhat-node (RHEL; worker)
  └── amazon-node (Amazon Linux; worker)
          |
          | Ansible over SSH
          v
  Ubuntu / Red Hat / Amazon Linux workers
```

This example uses region `ap-south-1` (Mumbai). The configuration uses
the default VPC and its subnets to keep the lab concise. For production,
build a dedicated VPC with private worker subnets, a bastion/SSM access
pattern, and carefully scoped security groups.

------------------------------------------------------------------------

# Part A --- Local computer setup

## Step 1. Install Terraform

### Ubuntu / Debian Linux

``` bash
sudo apt-get update
sudo apt-get install -y gnupg software-properties-common curl
wget -O- https://apt.releases.hashicorp.com/gpg \
  | gpg --dearmor \
  | sudo tee /usr/share/keyrings/hashicorp-archive-keyring.gpg >/dev/null
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(. /etc/os-release && echo ${VERSION_CODENAME}) main" \
  | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update
sudo apt-get install -y terraform
terraform -version
```

### macOS with Homebrew

``` bash
brew tap hashicorp/tap
brew install hashicorp/tap/terraform
terraform -version
```

### Windows

Install Terraform using the official instructions:\
https://developer.hashicorp.com/terraform/install

## Step 2. Install AWS CLI v2

### Ubuntu / Debian (x86_64)

``` bash
sudo apt-get update
sudo apt-get install -y curl unzip
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
aws --version
rm -rf aws awscliv2.zip
```

For ARM64 Linux, use
`https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip` instead.

### macOS

``` bash
curl "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o "AWSCLIV2.pkg"
sudo installer -pkg AWSCLIV2.pkg -target /
aws --version
```

Official guide:
https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html

## Step 3. Create an IAM identity for Terraform

In AWS Console, create a dedicated IAM user or (preferably where
possible) use IAM Identity Center/role-based credentials. Grant only the
permissions needed for this lab: EC2 instance, security group,
key-pair-related operations, and read access to AMI/region metadata. If
you later configure a remote Terraform backend, add only the required S3
and DynamoDB permissions for that backend.

Do not create root-account access keys. Do not paste secret keys into
source code or commit them.

Configure credentials:

``` bash
aws configure
```

Enter the access key and secret key from your IAM identity, default
region `ap-south-1`, and output format `json`. Then verify:

``` bash
aws sts get-caller-identity
aws configure list
aws ec2 describe-availability-zones --region ap-south-1
```

Credentials are normally stored in `~/.aws/credentials` and
`~/.aws/config`. Keep them private.

## Step 4. Generate an SSH key locally

On your local computer:

``` bash
mkdir -p ~/.ssh
ssh-keygen -t ed25519 -f ~/.ssh/terra-key-ansible -C "terraform-ansible-lab"
chmod 600 ~/.ssh/terra-key-ansible
chmod 644 ~/.ssh/terra-key-ansible.pub
```

-   Private key: `~/.ssh/terra-key-ansible`
-   Public key: `~/.ssh/terra-key-ansible.pub`

Terraform below uploads the **public key** to AWS as an EC2 key pair.
Never upload the private key to Terraform or Git.

------------------------------------------------------------------------

# Part B --- Terraform project

## Step 5. Create the project and files

``` bash
mkdir -p ~/terraform-ansible-lab
cd ~/terraform-ansible-lab
touch provider.tf terraform.tf ec2.tf variable.tf output.tf
```

File purpose:

  File             Purpose
  ---------------- ------------------------------------------------------
  `provider.tf`    AWS provider and region
  `terraform.tf`   Terraform version requirements
  `variable.tf`    Customizable values
  `ec2.tf`         AMI lookups, key pair, security group, EC2 instances
  `output.tf`      Public/private IP outputs

### 5.1 `terraform.tf`

``` hcl
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
```

### 5.2 `provider.tf`

``` hcl
provider "aws" {
  region = var.aws_region
}
```

The AWS provider uses credentials from the standard AWS CLI credential
chain. Do not put access keys in this file.

### 5.3 `variable.tf`

``` hcl
variable "aws_region" {
  description = "AWS region for this lab"
  type        = string
  default     = "ap-south-1"
}

variable "project_name" {
  description = "Prefix used for resource names"
  type        = string
  default     = "ansible-terra-lab"
}

variable "public_key_path" {
  description = "Local path to the SSH public key"
  type        = string
  default     = "~/.ssh/terra-key-ansible.pub"
}

variable "my_ip_cidr" {
  description = "Your public IPv4 address with /32, e.g. 203.0.113.10/32"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type for this learning lab"
  type        = string
  default     = "t3.micro"
}
```

Find your public IP using a trusted IP-check website, then provide it as
`x.x.x.x/32`. If RHEL is not eligible for the selected
free-tier/credits, it may incur charges; verify the current EC2 pricing
before applying.

### 5.4 `ec2.tf`

``` hcl
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Canonical Ubuntu 22.04 LTS AMI published by Canonical.
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Amazon Linux 2023 AMI published by Amazon.
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["137112412989"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# RHEL AMI published by Red Hat. RHEL pricing/licensing may apply.
data "aws_ami" "redhat" {
  most_recent = true
  owners      = ["309956199498"]

  filter {
    name   = "name"
    values = ["RHEL-9*_HVM-*-x86_64-*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_key_pair" "ansible" {
  key_name   = "${var.project_name}-key"
  public_key = file(pathexpand(var.public_key_path))
}

resource "aws_security_group" "lab" {
  name        = "${var.project_name}-sg"
  description = "SSH access from the administrator IP; worker SSH from the lab instances"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH from your public IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }

  ingress {
    description = "SSH between instances in this security group"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    self        = true
  }

  egress {
    description = "Outbound traffic for package downloads and administration"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-sg"
  }
}

locals {
  nodes = {
    master = {
      name = "master-node"
      ami  = data.aws_ami.ubuntu.id
    }
    ubuntu = {
      name = "ubuntu-node"
      ami  = data.aws_ami.ubuntu.id
    }
    redhat = {
      name = "redhat-node"
      ami  = data.aws_ami.redhat.id
    }
    amazon = {
      name = "amazon-node"
      ami  = data.aws_ami.amazon_linux.id
    }
  }
}

resource "aws_instance" "node" {
  for_each                    = local.nodes
  ami                         = each.value.ami
  instance_type               = var.instance_type
  key_name                    = aws_key_pair.ansible.key_name
  subnet_id                   = data.aws_subnets.default.ids[0]
  vpc_security_group_ids      = [aws_security_group.lab.id]
  associate_public_ip_address = true

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name    = each.value.name
    Project = var.project_name
    Role    = each.key
  }
}
```

**Notes about security groups:** The first SSH rule allows your local IP
to SSH into the instances. The self-referencing rule allows instances in
this group to SSH to one another. For a more secure design, do not
assign public IPs to worker nodes and use private subnets plus Systems
Manager Session Manager or a controlled bastion host.

### 5.5 `output.tf`

``` hcl
output "instance_public_ips" {
  description = "Public IP addresses for the four instances"
  value = {
    for name, instance in aws_instance.node :
    name => instance.public_ip
  }
}

output "instance_private_ips" {
  description = "Private IP addresses for Ansible inventory"
  value = {
    for name, instance in aws_instance.node :
    name => instance.private_ip
  }
}

output "instance_ids" {
  description = "EC2 instance IDs"
  value = {
    for name, instance in aws_instance.node :
    name => instance.id
  }
}
```

### 5.6 Create `terraform.tfvars`

This file is local configuration; do not commit it.

``` hcl
aws_region      = "ap-south-1"
project_name    = "ansible-terra-lab"
public_key_path = "~/.ssh/terra-key-ansible.pub"
my_ip_cidr      = "YOUR_PUBLIC_IP/32"
instance_type   = "t3.micro"
```

Replace `YOUR_PUBLIC_IP/32` with your actual public IPv4 address, for
example `198.51.100.25/32` is only a documentation example and will not
work for your network.

## Step 6. Run Terraform in order

Run all commands from `~/terraform-ansible-lab`.

``` bash
terraform fmt -recursive
terraform init
terraform validate
terraform plan -out=tfplan
terraform show tfplan
terraform apply tfplan
```

What they do:

-   `terraform fmt`: formats HCL files.
-   `terraform init`: downloads the provider and initializes the working
    directory. Run it on first setup and when provider/module/backend
    configuration changes.
-   `terraform validate`: checks configuration syntax and internal
    consistency.
-   `terraform plan`: previews proposed AWS changes.
-   `terraform apply`: creates the planned resources.

Get the IPs:

``` bash
terraform output
terraform output -json
terraform state list
```

Save the output. Use **private IPs** for Ansible connections when the
master can reach workers over the VPC. The public IPs are for your local
SSH connection to the master.

## Step 7. Connect from your local computer to the master

``` bash
chmod 600 ~/.ssh/terra-key-ansible
ssh -i ~/.ssh/terra-key-ansible ubuntu@MASTER_PUBLIC_IP
```

Replace `MASTER_PUBLIC_IP` with the `master` value from
`terraform output instance_public_ips`. Accept the host key only if you
expect to be connecting to that instance.

------------------------------------------------------------------------

# Part C --- Configure the Ansible master

## Step 8. Update packages and install Ansible

Run these commands **on `master-node`** (Ubuntu):

``` bash
sudo apt-get update
sudo apt-get upgrade -y
sudo apt-get install -y software-properties-common python3 python3-pip python3-venv git curl unzip
sudo apt-get install -y ansible
ansible --version
python3 --version
```

If the Ubuntu repository's Ansible version is suitable, `apt` is the
simplest method for this lab. For newer Ansible versions, use a Python
virtual environment and follow the official Ansible installation
documentation rather than mixing package-manager and pip installs.

## Step 9. Copy the private key to the master (requested lab method)

**Security warning:** The private key grants access to the worker nodes.
Copying it to the master means anyone who compromises the master may be
able to access the workers. A safer option is to create a dedicated key
on the master and add its public key to each worker's
`~/.ssh/authorized_keys`.

From your **local computer**, run:

``` bash
scp -i ~/.ssh/terra-key-ansible \
  ~/.ssh/terra-key-ansible \
  ubuntu@MASTER_PUBLIC_IP:/home/ubuntu/terra-key-ansible
```

This assumes the EC2 login key is also the key you are copying. The
destination must be writable by `ubuntu`.

Then connect to the master and lock down permissions:

``` bash
ssh -i ~/.ssh/terra-key-ansible ubuntu@MASTER_PUBLIC_IP
chmod 600 /home/ubuntu/terra-key-ansible
chown ubuntu:ubuntu /home/ubuntu/terra-key-ansible
ls -l /home/ubuntu/terra-key-ansible
```

Do not paste the private key into a terminal command, chat, or README.
Do not store it in a public repository.

## Step 10. Create the Ansible project structure

On `master-node`:

``` bash
mkdir -p ~/ansible-lab/playbooks
cd ~/ansible-lab
touch hosts.ini
```

### 10.1 `hosts.ini`

Use the **private IPs** from Terraform outputs. Replace each placeholder
with the corresponding actual private IP. The example assumes Ubuntu
login user `ubuntu` and Amazon Linux / RHEL login user `ec2-user`.

``` ini
[ubuntu_workers]
ubuntu-node ansible_host=UBUNTU_NODE_PRIVATE_IP ansible_user=ubuntu

[redhat_workers]
redhat-node ansible_host=REDHAT_NODE_PRIVATE_IP ansible_user=ec2-user

[amazon_workers]
amazon-node ansible_host=AMAZON_NODE_PRIVATE_IP ansible_user=ec2-user

[workers:children]
ubuntu_workers
redhat_workers
amazon_workers

[workers:vars]
ansible_ssh_private_key_file=/home/ubuntu/terra-key-ansible
ansible_python_interpreter=auto_silent
```

**Important:** RHEL images may use a different default login user
depending on the AMI publisher. If `ec2-user` fails for your RHEL AMI,
check that AMI's connection instructions and update `ansible_user`
accordingly. Do not assume every Red Hat image uses the same user.

Validate the inventory:

``` bash
cd ~/ansible-lab
ansible-inventory -i hosts.ini --graph
ansible-inventory -i hosts.ini --list
```

## Step 11. Test SSH and Ansible connectivity

Test SSH to each private IP from the master:

``` bash
ssh -i /home/ubuntu/terra-key-ansible ubuntu@UBUNTU_NODE_PRIVATE_IP
ssh -i /home/ubuntu/terra-key-ansible ec2-user@REDHAT_NODE_PRIVATE_IP
ssh -i /home/ubuntu/terra-key-ansible ec2-user@AMAZON_NODE_PRIVATE_IP
```

Exit each worker shell before continuing.

Test Ansible:

``` bash
ansible -i hosts.ini workers -m ping
ansible -i hosts.ini workers -m command -a "hostname"
ansible -i hosts.ini workers -m setup -a "filter=ansible_distribution*"
```

Expected result for successful ping: each worker returns
`"ping": "pong"`. If a worker returns `UNREACHABLE`, follow the
troubleshooting section.

------------------------------------------------------------------------

# Part D --- Ansible playbooks

## Step 12. Create `playbooks/install.yml`

This installs basic packages on Ubuntu, RHEL, and Amazon Linux. Package
names and package managers vary by OS, so the tasks use Ansible facts to
choose the appropriate package manager.

``` yaml
---
- name: Install common packages on all worker nodes
  hosts: workers
  become: true
  gather_facts: true

  tasks:
    - name: Install common packages on Ubuntu
      ansible.builtin.apt:
        name:
          - curl
          - git
          - unzip
          - python3
        state: present
        update_cache: true
        cache_valid_time: 3600
      when: ansible_os_family == "Debian"

    - name: Install common packages on Red Hat and Amazon Linux
      ansible.builtin.dnf:
        name:
          - curl
          - git
          - unzip
          - python3
        state: present
        update_cache: true
      when: ansible_os_family == "RedHat"

    - name: Show distribution details
      ansible.builtin.debug:
        msg: "{{ inventory_hostname }} is {{ ansible_distribution }} {{ ansible_distribution_version }}"
```

If a RHEL image has no valid subscription/repository access, package
installation may fail until its repository/subscription configuration is
resolved. Amazon Linux 2 may use `yum`; modern Amazon Linux 2023 uses
`dnf`.

Run:

``` bash
ansible-playbook -i hosts.ini playbooks/install.yml --syntax-check
ansible-playbook -i hosts.ini playbooks/install.yml
```

## Step 13. Create `playbooks/run_devboard.yml`

This example deploys a simple Dockerized application only if you have a
real image and the image supports the target CPU/OS. Replace the image
with your own published image. The task uses the `community.docker`
collection, which must be installed.

Install collection:

``` bash
ansible-galaxy collection install community.docker
```

Create the playbook:

``` yaml
---
- name: Run Devboard container on worker nodes
  hosts: workers
  become: true
  gather_facts: true

  vars:
    devboard_image: "nginx:stable"
    devboard_container_name: "devboard-demo"
    devboard_host_port: 8080
    devboard_container_port: 80

  tasks:
    - name: Install Docker on Ubuntu
      ansible.builtin.apt:
        name: docker.io
        state: present
        update_cache: true
      when: ansible_os_family == "Debian"

    - name: Install Docker on Red Hat-family nodes
      ansible.builtin.dnf:
        name: docker
        state: present
      when: ansible_os_family == "RedHat"

    - name: Start and enable Docker
      ansible.builtin.service:
        name: docker
        state: started
        enabled: true

    - name: Run demo container
      community.docker.docker_container:
        name: "{{ devboard_container_name }}"
        image: "{{ devboard_image }}"
        state: started
        restart_policy: unless-stopped
        published_ports:
          - "{{ devboard_host_port }}:{{ devboard_container_port }}"
```

This is a **working demo container**, not your actual Devboard
application yet. Replace `nginx:stable` with your real application image
and set its correct container port and environment variables. Docker
package availability differs by distribution; if a package is
unavailable, use that distribution's official Docker installation
instructions.

Run:

``` bash
ansible-playbook -i hosts.ini playbooks/run_devboard.yml --syntax-check
ansible-playbook -i hosts.ini playbooks/run_devboard.yml --check
ansible-playbook -i hosts.ini playbooks/run_devboard.yml
```

The `--check` dry run may not predict every container/module action. To
verify:

``` bash
ansible -i hosts.ini workers -b -m command -a "docker ps"
```

To test a web endpoint from the master, use
`curl http://WORKER_PRIVATE_IP:8080` only after ensuring network rules
permit the traffic. Do not open port 8080 to the public internet unless
you need to and have restricted access.

------------------------------------------------------------------------

# Part E --- Troubleshooting checklist

## Terraform issues

### `terraform: command not found`

``` bash
terraform -version
which terraform
```

Reinstall Terraform using the official install steps for your OS.

### AWS credentials / `Unable to locate credentials`

``` bash
aws configure list
aws sts get-caller-identity
```

Reconfigure the intended profile or export `AWS_PROFILE=your-profile`.
Never paste secret keys into code or logs.

### `UnauthorizedOperation` / access denied

The IAM identity lacks one or more required permissions. Review the
exact denied API action in the error and grant only that permission to
the Terraform identity.

### AMI lookup returns no results

``` bash
aws ec2 describe-images --region ap-south-1 --owners 099720109477 \
  --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"
```

Check region, architecture, AMI owner, and filter pattern. AMI names can
change over time.

### `InvalidKeyPair.NotFound` or key errors

Check the configured public-key path:

``` bash
ls -l ~/.ssh/terra-key-ansible.pub
ssh-keygen -lf ~/.ssh/terra-key-ansible.pub
```

Terraform creates the AWS key pair from the public key; the private key
stays local.

### SSH times out

``` bash
terraform output
aws ec2 describe-instances --region ap-south-1 \
  --query "Reservations[].Instances[].[Tags[?Key=='Name']|[0].Value,State.Name,PublicIpAddress,PrivateIpAddress,SecurityGroups[].GroupId]" \
  --output table
```

Check instance state, current local public IP in `my_ip_cidr`, route
table, subnet internet gateway, and security-group rules. If your
ISP/VPN changes your public IP, update `my_ip_cidr` and apply again.

### Inspect and clean up Terraform state

``` bash
terraform state list
terraform state show 'aws_instance.node["master"]'
terraform plan
```

Do not manually edit `terraform.tfstate`. Back it up securely; it can
contain sensitive information.

## Ansible / SSH issues

### `UNREACHABLE!` / `Permission denied (publickey)`

``` bash
chmod 600 /home/ubuntu/terra-key-ansible
ssh -vvv -i /home/ubuntu/terra-key-ansible ubuntu@UBUNTU_NODE_PRIVATE_IP
ssh -vvv -i /home/ubuntu/terra-key-ansible ec2-user@AMAZON_NODE_PRIVATE_IP
```

Verify the private key matches the EC2 key pair, the correct OS login
username is used, and the public key was installed at instance launch.
If the key is wrong, use a supported recovery method or recreate the lab
instances with the correct key pair.

### `Host key verification failed`

For a disposable lab only, remove the specific stale host entry and
reconnect:

``` bash
ssh-keygen -R WORKER_PRIVATE_IP
```

Do not disable host-key checking globally as a routine fix.

### `sudo: a password is required`

Confirm the account is allowed to use passwordless sudo on the AMI. Test
with:

``` bash
ansible -i hosts.ini workers -b -m command -a "id"
```

Do not store sudo passwords in plain text. Use Ansible Vault if a
password is genuinely required.

### `Python interpreter not found`

``` bash
ansible -i hosts.ini workers -m raw -a "command -v python3 || command -v python"
```

Install Python using the OS package manager, then rerun facts. If the
host has no Python initially, Ansible's `raw` module can bootstrap it.

### Inventory syntax or group errors

``` bash
ansible-inventory -i hosts.ini --graph
ansible-inventory -i hosts.ini --list
```

Group variables must be placed under a valid group section such as
`[workers:vars]`. Do not put `ansible_ssh_private_key_file=...` as a
standalone line outside a group.

### `apt` works but `dnf` task fails

Check the target distribution:

``` bash
ansible -i hosts.ini workers -m setup -a "filter=ansible_os_family"
ansible -i hosts.ini workers -m setup -a "filter=ansible_distribution*"
```

RHEL subscription/repository configuration and Amazon Linux package
names differ. Use the appropriate package manager and repositories for
the actual AMI.

### Ansible verbose debugging

``` bash
ansible -i hosts.ini workers -m ping -vvv
ansible-playbook -i hosts.ini playbooks/install.yml -vvv
```

------------------------------------------------------------------------

# Part F --- Useful daily command sequence

On your **local computer**:

``` bash
cd ~/terraform-ansible-lab
aws sts get-caller-identity
terraform fmt -recursive
terraform init
terraform validate
terraform plan
terraform apply
terraform output
ssh -i ~/.ssh/terra-key-ansible ubuntu@MASTER_PUBLIC_IP
```

On the **master-node**:

``` bash
cd ~/ansible-lab
ansible-inventory -i hosts.ini --graph
ansible -i hosts.ini workers -m ping
ansible -i hosts.ini workers -m command -a "hostname"
ansible-playbook -i hosts.ini playbooks/install.yml
ansible-playbook -i hosts.ini playbooks/run_devboard.yml
```

## Important Terraform reminders

-   `terraform init` is required on first setup and when provider,
    module, or backend configuration changes. It is not normally
    required just because a resource, variable, output, or data block
    changed.
-   Review `terraform plan` before applying.
-   Terraform state is sensitive and must be protected.
-   A change to the security group or instance configuration may replace
    or modify resources; inspect the plan before proceeding.
-   A local state file is fine for a personal lab, but team use should
    use a secured remote backend with locking and encryption.

## Destroy the lab when finished

This deletes resources managed by this Terraform configuration:

``` bash
cd ~/terraform-ansible-lab
terraform plan -destroy
terraform destroy
```

Review the plan carefully before confirming. EC2/RHEL usage, EBS
volumes, snapshots, public IPv4 addresses, and other resources can incur
charges. Confirm in the AWS Console that the lab resources are removed.

## Official references

-   Terraform install: https://developer.hashicorp.com/terraform/install
-   Terraform AWS provider:
    https://registry.terraform.io/providers/hashicorp/aws/latest/docs
-   AWS CLI install:
    https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
-   AWS CLI configure:
    https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-quickstart.html
-   EC2 key pairs:
    https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-key-pairs.html
-   Ansible install:
    https://docs.ansible.com/ansible/latest/installation_guide/intro_installation.html
-   Ansible inventory:
    https://docs.ansible.com/ansible/latest/inventory_guide/intro_inventory.html
-   Ansible Docker collection:
    https://docs.ansible.com/ansible/latest/collections/community/docker/docker_container_module.html
