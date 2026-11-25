terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.region
}

# ======================= VPC =======================
resource "aws_vpc" "lab" {
  cidr_block = "10.10.0.0/16"
  tags = { Name = "lab04-vpc" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.lab.id
  tags   = { Name = "lab04-igw" }
}

# ================= SUBREDES PÚBLICAS (ALB + NAT) =================
resource "aws_subnet" "pub_a" {
  vpc_id                  = aws_vpc.lab.id
  cidr_block              = "10.10.1.0/24"
  availability_zone       = var.azs[0]
  map_public_ip_on_launch = true
  tags = { Name = "lab04-publica-a" }
}

resource "aws_subnet" "pub_b" {
  vpc_id                  = aws_vpc.lab.id
  cidr_block              = "10.10.2.0/24"
  availability_zone       = var.azs[1]
  map_public_ip_on_launch = true
  tags = { Name = "lab04-publica-b" }
}

# ================= SUBREDES PRIVADAS (servidores) =================
resource "aws_subnet" "priv_a" {
  vpc_id            = aws_vpc.lab.id
  cidr_block        = "10.10.11.0/24"
  availability_zone = var.azs[0]
  tags = { Name = "lab04-privada-a" }
}

resource "aws_subnet" "priv_b" {
  vpc_id            = aws_vpc.lab.id
  cidr_block        = "10.10.12.0/24"
  availability_zone = var.azs[1]
  tags = { Name = "lab04-privada-b" }
}

# ================= NAT GATEWAY =================
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "lab04-nat-eip" }
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.pub_a.id        # el NAT vive en una subred PÚBLICA
  tags          = { Name = "lab04-nat" }
  depends_on    = [aws_internet_gateway.igw]
}

# ================= TABLAS DE RUTEO =================
resource "aws_route_table" "publica" {
  vpc_id = aws_vpc.lab.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id   # pública → Internet Gateway
  }
  tags = { Name = "lab04-rt-publica" }
}

resource "aws_route_table" "privada" {
  vpc_id = aws_vpc.lab.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id    # privada → NAT Gateway
  }
  tags = { Name = "lab04-rt-privada" }
}

resource "aws_route_table_association" "pub_a" {
  subnet_id      = aws_subnet.pub_a.id
  route_table_id = aws_route_table.publica.id
}

resource "aws_route_table_association" "pub_b" {
  subnet_id      = aws_subnet.pub_b.id
  route_table_id = aws_route_table.publica.id
}

resource "aws_route_table_association" "priv_a" {
  subnet_id      = aws_subnet.priv_a.id
  route_table_id = aws_route_table.privada.id
}

resource "aws_route_table_association" "priv_b" {
  subnet_id      = aws_subnet.priv_b.id
  route_table_id = aws_route_table.privada.id
}

# ================= SECURITY GROUPS =================
resource "aws_security_group" "alb" {
  name        = "lab04-alb-sg"
  description = "HTTP desde internet hacia el ALB"
  vpc_id      = aws_vpc.lab.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "lab04-alb-sg" }
}

resource "aws_security_group" "web" {
  name        = "lab04-web-sg"
  description = "HTTP solo desde el ALB"
  vpc_id      = aws_vpc.lab.id

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "lab04-web-sg" }
}

# ============ IAM ROLE PARA SSM (permisos de la VM) ============
resource "aws_iam_role" "ssm" {
  name = "lab04-ec2-ssm-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ssm" {
  name = "lab04-ec2-ssm-profile"
  role = aws_iam_role.ssm.name
}

# ================= LAUNCH TEMPLATE =================
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023*-x86_64"]
  }
}

resource "aws_launch_template" "web" {
  name_prefix            = "lab04-web-"
  image_id               = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  vpc_security_group_ids = [aws_security_group.web.id]

  iam_instance_profile {
    name = aws_iam_instance_profile.ssm.name
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    dnf install -y httpd
    TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
    ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
    AZ=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone)
    IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4)
    echo "<h1>Lab04 - Servidores privados</h1><p>Servidor: $ID</p><p>Zona: $AZ</p><p>IP privada: $IP</p>" > /var/www/html/index.html
    systemctl enable --now httpd
  EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "lab04-web" }
  }
}


# ================= CERTIFICADO (autofirmado, solo para lab) =================
resource "tls_private_key" "lab" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "lab" {
  private_key_pem = tls_private_key.lab.private_key_pem
  subject {
    common_name  = "lab04.local"
    organization = "Lab Jose"
  }
  validity_period_hours = 720
  allowed_uses          = ["key_encipherment", "digital_signature", "server_auth"]
}

resource "aws_acm_certificate" "lab" {
  private_key      = tls_private_key.lab.private_key_pem
  certificate_body = tls_self_signed_cert.lab.cert_pem
  tags             = { Name = "lab04-cert" }
}

# ================= LOAD BALANCER (en subredes PÚBLICAS) =================
resource "aws_lb_target_group" "web" {
  name                 = "lab04-tg"
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
  name               = "lab04-alb"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb.id]
  subnets            = [aws_subnet.pub_a.id, aws_subnet.pub_b.id]
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.web.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.web.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate.lab.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
}

# ================= AUTO SCALING (en subredes PRIVADAS) =================
resource "aws_autoscaling_group" "web" {
  name                      = "lab04-asg"
  min_size                  = var.cantidad_servidores
  max_size                  = var.cantidad_servidores + 2
  desired_capacity          = var.cantidad_servidores
  vpc_zone_identifier       = [aws_subnet.priv_a.id, aws_subnet.priv_b.id]
  target_group_arns         = [aws_lb_target_group.web.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 120

  launch_template {
    id      = aws_launch_template.web.id
    version = "$Latest"
  }

  # Esperar a que exista la salida por NAT antes de crear servidores
  depends_on = [
    aws_route_table_association.priv_a,
    aws_route_table_association.priv_b,
  ]
}





# ================= SALIDAS =================
output "url" {
  value = "https://${aws_lb.web.dns_name}"
}

output "nat_ip_publica" {
  value = aws_eip.nat.public_ip
}