# main.tf: Contains the core resource declarations and configurations for the module.

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "main" {
  cidr_block           = var.cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(var.tags, {
    Name = var.name
  })
}