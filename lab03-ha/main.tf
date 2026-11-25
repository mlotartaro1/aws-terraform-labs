terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.region
}

# ======================= RED =======================
resource "aws_vpc" "lab" {
  cidr_block = "10.10.0.0/16"
  tags = { Name = "lab03-vpc" }
}

resource "aws_subnet" "a" {
  vpc_id                  = aws_vpc.lab.id
  cidr_block              = "10.10.1.0/24"
  availability_zone       = var.azs[0]
  map_public_ip_on_launch = true
  tags = { Name = "lab03-subnet-a" }
}

resource "aws_subnet" "b" {
  vpc_id                  = aws_vpc.lab.id
  cidr_block              = "10.10.2.0/24"
  availability_zone       = var.azs[1]
  map_public_ip_on_launch = true
  tags = { Name = "lab03-subnet-b" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.lab.id
  tags   = { Name = "lab03-igw" }
}

resource "aws_route_table" "publica" {
  vpc_id = aws_vpc.lab.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "lab03-rt-publica" }
}

resource "aws_route_table_association" "a" {
  subnet_id      = aws_subnet.a.id
  route_table_id = aws_route_table.publica.id
}

resource "aws_route_table_association" "b" {
  subnet_id      = aws_subnet.b.id
  route_table_id = aws_route_table.publica.id
}

# ================= SECURITY GROUPS =================
# SG del balanceador: abierto a Internet en el puerto 80
resource "aws_security_group" "alb" {
  name        = "lab03-alb-sg"
  description = "HTTP desde internet hacia el ALB"
  vpc_id      = aws_vpc.lab.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "lab03-alb-sg" }
}

# SG de los servidores: puerto 80 SOLO desde el SG del ALB
resource "aws_security_group" "web" {
  name        = "lab03-web-sg"
  description = "HTTP solo desde el ALB"
  vpc_id      = aws_vpc.lab.id

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]   # origen = otro SG
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "lab03-web-sg" }
}

# ============ LAUNCH TEMPLATE (la "receta") ============
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023*-x86_64"]
  }
}

resource "aws_launch_template" "web" {
  name_prefix            = "lab03-web-"
  image_id               = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  vpc_security_group_ids = [aws_security_group.web.id]

  user_data = base64encode(<<-EOF
    #!/bin/bash
    dnf install -y httpd
    TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
    ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
    AZ=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone)
    echo "<h1>Lab03 - Alta disponibilidad</h1><p>Servidor: $ID</p><p>Zona: $AZ</p>" > /var/www/html/index.html
    systemctl enable --now httpd
  EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "lab03-web" }
  }
}

# ================= LOAD BALANCER =================
resource "aws_lb_target_group" "web" {
  name                 = "lab03-tg"
  port                 = 80
  protocol             = "HTTP"
  vpc_id               = aws_vpc.lab.id
  deregistration_delay = 30

  health_check {
    path                = "/"
    matcher             = "200"
    interval            = 10
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb" "web" {
  name               = "lab03-alb"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb.id]
  subnets            = [aws_subnet.a.id, aws_subnet.b.id]
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.web.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
}

# ================= AUTO SCALING GROUP =================
resource "aws_autoscaling_group" "web" {
  name                      = "lab03-asg"
  min_size                  = var.cantidad_servidores
  max_size                  = var.cantidad_servidores + 2
  desired_capacity          = var.cantidad_servidores
  vpc_zone_identifier       = [aws_subnet.a.id, aws_subnet.b.id]
  target_group_arns         = [aws_lb_target_group.web.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 120

  launch_template {
    id      = aws_launch_template.web.id
    version = "$Latest"
  }
}

# ================= SALIDA =================
output "url" {
  value = "http://${aws_lb.web.dns_name}"
}