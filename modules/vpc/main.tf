# ----------------------------------------
# Locals: Helper values used throughout the module
# ----------------------------------------
# Select only the first N Availability Zones. This ensures deterministic subnet placement
# regardless of how many AZs exist in a region.

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)
}

# Fetch all AZs that are currently available in the region.
data "aws_availability_zones" "available" {
  state = "available"
}

# ----------------------------------------
# VPC
# ----------------------------------------

resource "aws_vpc" "main" {
  cidr_block           = var.cidr
  enable_dns_hostnames = true   # Required for EC2 instances to receive DNS names
  enable_dns_support   = true   # Enables internal DNS resolution

  # Merge user-provided tags with module-generated tags
  tags = merge(var.tags, {
    Name = var.name
  })
}

# ----------------------------------------
# Public Subnets (one per AZ)
# ----------------------------------------

resource "aws_subnet" "public" {
  count                   = var.az_count
  vpc_id                  = aws_vpc.main.id

  # Generate unique CIDRs per subnet. The "8" bitmask provides up to 256 subnets.
  cidr_block              = cidrsubnet(var.cidr, 8, count.index)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true  # Required for internet-facing EC2 instances

  tags = merge(var.tags, {
    Name = "${var.name}-public-${local.azs[count.index]}"
    Tier = "Public"
  })
}

# Internet gateway for outbound access from public subnets
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = merge(var.tags, {
    Name = var.name
  })
}

# Route table for public subnets (shared across all public subnets)
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  tags = merge(var.tags, {
    Name = "${var.name}-public"
  })
}

# Default route for public subnets → Internet Gateway
resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}

# Associate each public subnet with the public route table
resource "aws_route_table_association" "public" {
  count          = var.az_count
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ----------------------------------------
# Private Subnets (one per AZ)
# ----------------------------------------

resource "aws_subnet" "private" {
  count             = var.az_count
  vpc_id            = aws_vpc.main.id

  # Generate unique CIDRs for private subnets by offsetting the index
  cidr_block        = cidrsubnet(var.cidr, 8, count.index + var.az_count)
  availability_zone = local.azs[count.index]

  tags = merge(var.tags, {
    Name = "${var.name}-private-${local.azs[count.index]}"
    Tier = "Private"
  })
}

# ----------------------------------------
# NAT Gateways
# ----------------------------------------
# EIPs for NAT Gateways
# NAT strategy:
# - If enable_nat_gateway = false → no NAT is created
# - If single_nat_gateway = true → one shared NAT for all AZs
# - Otherwise → one NAT per AZ for HA

resource "aws_eip" "nat" {
  count  = var.enable_nat_gateway ? (var.single_nat_gateway ? 1 : var.az_count) : 0
  domain = "vpc"

  tags = merge(var.tags, {
    Name = "${var.name}-nat"
  })
}

resource "aws_nat_gateway" "nat" {
  count         = var.enable_nat_gateway ? (var.single_nat_gateway ? 1 : var.az_count) : 0
  allocation_id = aws_eip.nat[count.index].id

  # NAT must sit in a public subnet
  subnet_id = aws_subnet.public[count.index % var.az_count].id

  tags = merge(var.tags, {
    Name = var.name
  })
}

# ----------------------------------------
# Private Route Tables
# ----------------------------------------

resource "aws_route_table" "private" {
  count  = var.az_count
  vpc_id = aws_vpc.main.id

  tags = merge(var.tags, {
    Name = "${var.name}-private-${local.azs[count.index]}"
  })
}

# Default route for private subnets → NAT Gateway
resource "aws_route" "private_nat" {
  count                  = var.enable_nat_gateway ? var.az_count : 0
  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"

  # If single_nat_gateway is enabled, all private RTs use NAT[0]
  nat_gateway_id = var.single_nat_gateway ?
    aws_nat_gateway.nat[0].id :
    aws_nat_gateway.nat[count.index].id
}

# Associate private subnets with their corresponding private route tables
resource "aws_route_table_association" "private" {
  count          = var.az_count
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}
