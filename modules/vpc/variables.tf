variable "name" {
  description = "Base name for VPC resources"
  type        = string
}

variable "cidr" {
  description = "CIDR block for the VPC"
  type        = string
}

variable "az_count" {
  description = "Number of availability zones to use"
  type        = number
}

variable "enable_nat_gateway" {
  description = "Whether to create NAT gateways"
  type        = bool
  default     = false
}

variable "single_nat_gateway" {
  description = "Create only a single NAT gateway"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Common tags applied to all VPC resources"
  type        = map(string)
  default     = {}
}