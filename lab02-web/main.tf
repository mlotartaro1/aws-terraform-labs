terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = "us-east-2"
}

# ---------- RED (igual que el lab01) ----------
resource "aws_vpc" "lab" {
  cidr_block = "10.10.0.0/16"
  tags = { Name = "lab02-vpc" }
}

resource "aws_subnet" "publica" {
  vpc_id                  = aws_vpc.lab.id
  cidr_block              = "10.10.1.0/24"
  availability_zone       = "us-east-2a"
  map_public_ip_on_launch = true
  tags = { Name = "lab02-subnet-publica" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.lab.id
  tags   = { Name = "lab02-igw" }
}

resource "aws_route_table" "publica" {
  vpc_id = aws_vpc.lab.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "lab02-rt-publica" }
}

resource "aws_route_table_association" "publica" {
  subnet_id      = aws_subnet.publica.id
  route_table_id = aws_route_table.publica.id
}

# ---------- NUEVO: Security Group (firewall) ----------
resource "aws_security_group" "web" {
  name        = "lab02-web-sg"
  description = "Permite HTTP desde internet"
  vpc_id      = aws_vpc.lab.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Salida a todo"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "lab02-web-sg" }
}

# ---------- NUEVO: buscar la imagen de Amazon Linux más reciente ----------
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023*-x86_64"]
  }
}

# ---------- NUEVO: el servidor web ----------
resource "aws_instance" "web" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.publica.id
  vpc_security_group_ids = [aws_security_group.web.id]

  user_data = <<-EOF
    #!/bin/bash
    dnf install -y httpd
    echo "<h1>Hola Jose! Este servidor lo creaste con Terraform</h1><p>Host: $(hostname -f)</p>" > /var/www/html/index.html
    systemctl enable --now httpd
  EOF

  tags = { Name = "lab02-web" }
}

output "url" {
  value = "http://${aws_instance.web.public_ip}"
}