terraform {
  required_version = ">= 1.3.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

locals {
  name_prefix = "ailab-${var.participant_name}"
  common_tags = {
    Project     = "ai-lab"
    Participant = var.participant_name
  }
}

data "aws_ssm_parameter" "ubuntu_ami" {
  name = "/aws/service/canonical/ubuntu/server/22.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

data "aws_ssm_parameter" "windows_ami" {
  name = "/aws/service/ami-windows-latest/Windows_Server-2022-English-Full-Base"
}

resource "aws_vpc" "lab" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, {
    Name = "vpc-${local.name_prefix}"
  })
}

resource "aws_subnet" "app" {
  vpc_id            = aws_vpc.lab.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "${var.aws_region}a"

  tags = merge(local.common_tags, {
    Name = "snet-app"
  })
}

resource "aws_subnet" "db" {
  vpc_id            = aws_vpc.lab.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "${var.aws_region}a"

  tags = merge(local.common_tags, {
    Name = "snet-db"
  })
}

resource "aws_subnet" "access" {
  vpc_id                  = aws_vpc.lab.id
  cidr_block              = "10.0.3.0/27"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name = "snet-access"
  })
}

resource "aws_internet_gateway" "lab" {
  vpc_id = aws_vpc.lab.id

  tags = merge(local.common_tags, {
    Name = "igw-${local.name_prefix}"
  })
}

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = merge(local.common_tags, {
    Name = "eip-nat-${local.name_prefix}"
  })
}

resource "aws_nat_gateway" "lab" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.access.id

  tags = merge(local.common_tags, {
    Name = "nat-${local.name_prefix}"
  })

  depends_on = [aws_internet_gateway.lab]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.lab.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.lab.id
  }

  tags = merge(local.common_tags, {
    Name = "rt-public-${local.name_prefix}"
  })
}

resource "aws_route_table_association" "access" {
  subnet_id      = aws_subnet.access.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.lab.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.lab.id
  }

  tags = merge(local.common_tags, {
    Name = "rt-private-${local.name_prefix}"
  })
}

resource "aws_route_table_association" "app" {
  subnet_id      = aws_subnet.app.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "db" {
  subnet_id      = aws_subnet.db.id
  route_table_id = aws_route_table.private.id
}

# Intentional security issues are preserved to match the original lab exercise.
resource "aws_security_group" "app" {
  name        = "sg-app-${var.participant_name}"
  description = "App/Windows SG for lab"
  vpc_id      = aws_vpc.lab.id

  ingress {
    description = "Allow SSH from internet"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Allow RDP from internet"
    from_port   = 3389
    to_port     = 3389
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "nsg-app"
  })
}

resource "aws_security_group" "db" {
  name        = "sg-db-${var.participant_name}"
  description = "DB SG for lab"
  vpc_id      = aws_vpc.lab.id

  ingress {
    description = "Allow PostgreSQL from app subnet"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["10.0.1.0/24"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "nsg-db"
  })
}

resource "aws_security_group" "eice" {
  name        = "sg-eice-${var.participant_name}"
  description = "EC2 Instance Connect Endpoint SG"
  vpc_id      = aws_vpc.lab.id

  ingress {
    description = "Allow EIC endpoint ingress"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.eice_allowed_cidrs
  }

  ingress {
    description = "Allow EIC endpoint RDP ingress"
    from_port   = 3389
    to_port     = 3389
    protocol    = "tcp"
    cidr_blocks = var.eice_allowed_cidrs
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "sg-eice"
  })
}

resource "aws_ec2_instance_connect_endpoint" "lab" {
  subnet_id          = aws_subnet.access.id
  security_group_ids = [aws_security_group.eice.id]

  tags = merge(local.common_tags, {
    Name = "eice-${local.name_prefix}"
  })
}

resource "aws_instance" "app" {
  ami                    = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type          = var.linux_instance_type
  subnet_id              = aws_subnet.app.id
  private_ip             = "10.0.1.10"
  vpc_security_group_ids = [aws_security_group.app.id]

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
  }

  tags = merge(local.common_tags, {
    Name = "vm-app"
  })
}

resource "aws_instance" "db" {
  ami                    = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type          = var.linux_instance_type
  subnet_id              = aws_subnet.db.id
  private_ip             = "10.0.2.10"
  vpc_security_group_ids = [aws_security_group.db.id]
  user_data_base64       = base64encode(file("${path.module}/cloud-init-db.yaml"))

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
  }

  tags = merge(local.common_tags, {
    Name = "vm-db"
  })
}

resource "aws_instance" "win" {
  ami                    = data.aws_ssm_parameter.windows_ami.value
  instance_type          = var.windows_instance_type
  subnet_id              = aws_subnet.app.id
  private_ip             = "10.0.1.20"
  vpc_security_group_ids = [aws_security_group.app.id]

  user_data = <<-EOT
    <powershell>
    net user Administrator "${var.admin_password}"
    </powershell>
  EOT

  root_block_device {
    volume_size = 128
    volume_type = "gp3"
  }

  tags = merge(local.common_tags, {
    Name = "vm-win"
  })
}

resource "random_string" "bucket_suffix" {
  length  = 6
  upper   = false
  numeric = true
  special = false
}

resource "aws_s3_bucket" "lab" {
  bucket        = "stailab-${var.participant_name}-${random_string.bucket_suffix.result}"
  force_destroy = true

  tags = merge(local.common_tags, {
    Name = "st-${local.name_prefix}"
  })
}

resource "aws_s3_bucket_public_access_block" "lab" {
  bucket                  = aws_s3_bucket.lab.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
