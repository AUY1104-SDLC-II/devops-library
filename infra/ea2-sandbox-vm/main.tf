data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

# Ubuntu oficial (Canonical) en AWS -> usuario SSH: ubuntu (apt, k3s/minikube compatibles).
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "random_id" "suffix" {
  byte_length = 4
}

data "aws_vpc" "default" {
  default = true
}

resource "aws_security_group" "lab" {
  name        = "ea2-lab-sg-${random_id.suffix.hex}"
  # AWS exige ASCII en GroupDescription (sin tildes ni guiones tipograficos).
  description = "EA2 lab: SSH + K8s API + NodePort range (academic sandbox)"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_cidr_ipv4]
  }

  # Sin esta regla, kubectl desde fuera de la VM hace timeout contra https://IP:6443 (solo habia SSH y NodePorts).
  ingress {
    description = "Kubernetes API (K3s kube-apiserver)"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = [var.k8s_api_cidr_ipv4]
  }

  ingress {
    description = "NodePort range (academic)"
    from_port   = var.k8s_nodeport_min
    to_port     = var.k8s_nodeport_max
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_key_pair" "lab" {
  key_name   = "ea2-lab-${random_id.suffix.hex}"
  public_key = var.public_key
}

resource "aws_instance" "lab" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  key_name               = aws_key_pair.lab.key_name
  vpc_security_group_ids = [aws_security_group.lab.id]

  root_block_device {
    volume_size           = var.root_volume_size
    volume_type           = var.root_volume_type
    delete_on_termination = true
  }

  tags = {
    Name        = "ea2-k8s-sandbox"
    Purpose     = "AUY1104-EA2-lab"
    ManagedBy   = "terraform"
    Environment = "academic-sandbox"
  }
}
