terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# Identifiants factices : permet "terraform plan" sans compte AWS (TD).
provider "aws" {
  region                      = "eu-west-3"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
}

locals {
  zones = ["eu-west-3a", "eu-west-3b"]

  subnets = {
    public_a = { cidr = "10.0.1.0/24", zone = 0, tier = "public" }
    public_b = { cidr = "10.0.11.0/24", zone = 1, tier = "public" }
    app_a    = { cidr = "10.0.2.0/24", zone = 0, tier = "app" }
    app_b    = { cidr = "10.0.12.0/24", zone = 1, tier = "app" }
    data_a   = { cidr = "10.0.3.0/24", zone = 0, tier = "data" }
    data_b   = { cidr = "10.0.13.0/24", zone = 1, tier = "data" }
  }

  app_port  = 8443
  data_port = 5432
}

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "flashticket-vpc" }
}

resource "aws_subnet" "this" {
  for_each = local.subnets

  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value.cidr
  availability_zone       = local.zones[each.value.zone]
  map_public_ip_on_launch = each.value.tier == "public"

  tags = {
    Name = "flashticket-${each.key}"
    Tier = each.value.tier
  }
}

# Public : HTTPS depuis Internet
resource "aws_security_group" "public" {
  name        = "flashticket-public"
  description = "Segment public : HTTPS entrant"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTPS depuis Internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Vers l applicatif"
    from_port   = local.app_port
    to_port     = local.app_port
    protocol    = "tcp"
    cidr_blocks = ["10.0.2.0/24", "10.0.12.0/24"]
  }

  tags = { Name = "flashticket-public" }
}

# Applicatif : n'accepte QUE le groupe public, sur 8443
resource "aws_security_group" "app" {
  name        = "flashticket-app"
  description = "Segment applicatif : ticketpdf"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "ticketpdf depuis le public uniquement"
    from_port       = local.app_port
    to_port         = local.app_port
    protocol        = "tcp"
    security_groups = [aws_security_group.public.id]
  }

  egress {
    description = "Vers les donnees"
    from_port   = local.data_port
    to_port     = local.data_port
    protocol    = "tcp"
    cidr_blocks = ["10.0.3.0/24", "10.0.13.0/24"]
  }

  tags = { Name = "flashticket-app" }
}

# Donnees : n'accepte QUE le groupe applicatif, sur 5432
resource "aws_security_group" "data" {
  name        = "flashticket-data"
  description = "Segment donnees : base PostgreSQL"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "PostgreSQL depuis l applicatif uniquement"
    from_port       = local.data_port
    to_port         = local.data_port
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  # Aucune regle egress : la base ne sort pas.

  tags = { Name = "flashticket-data" }
}

output "vpc_id" {
  value = aws_vpc.main.id
}

output "subnet_ids" {
  value = { for k, s in aws_subnet.this : k => s.id }
}