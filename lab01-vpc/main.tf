# 1. Provider: le dice a Terraform con qué nube hablar y en qué región
terraform {
  backend "s3" {
    bucket       = "tfstate-989925973894"
    key          = "lab01-vpc/terraform.tfstate"
    region       = "us-east-2"
    use_lockfile = true
    encrypt      = true
  }

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

# 2. Resource: cada bloque es un recurso a crear
#    Formato: resource "<tipo>" "<nombre_local>"
resource "aws_vpc" "lab" {
  cidr_block = "10.255.0.0/16"
  tags       = { Name = "lab01-vpc-test" }
}

resource "aws_subnet" "publica" {
  vpc_id                  = aws_vpc.lab.id # referencia a la VPC de arriba
  cidr_block              = "10.255.1.0/24"
  availability_zone       = "us-east-2a"
  map_public_ip_on_launch = true
  tags                    = { Name = "lab01-subnet-publica" }
}

resource "aws_subnet" "publica_b" {
  vpc_id                  = aws_vpc.lab.id
  cidr_block              = "10.255.2.0/24"
  availability_zone       = "us-east-2b"
  map_public_ip_on_launch = true
  tags                    = { Name = "lab01-subnet-publica-b" }
}

resource "aws_route_table_association" "publica_b" {
  subnet_id      = aws_subnet.publica_b.id
  route_table_id = aws_route_table.publica.id
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.lab.id
  tags   = { Name = "lab01-igw" }
}

resource "aws_route_table" "publica" {
  vpc_id = aws_vpc.lab.id

  route {
    cidr_block = "0.0.0.0/0"                 # ruta por defecto
    gateway_id = aws_internet_gateway.igw.id # next-hop: el IGW
  }
  tags = { Name = "lab01-rt-publica" }
}

resource "aws_route_table_association" "publica" {
  subnet_id      = aws_subnet.publica.id
  route_table_id = aws_route_table.publica.id
}

# 3. Output: muestra datos al terminar
output "vpc_id" {
  value = aws_vpc.lab.id
}