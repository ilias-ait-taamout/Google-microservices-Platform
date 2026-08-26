# =============================================================================
# modules/network — INPUTS
# =============================================================================
# A child module knows nothing about the environment using it. Anything that
# could differ between dev / staging / prod is declared here and supplied by
# the caller (envs/dev/main.tf).
#
# variables.tf DECLARES. terraform.tfvars (or the caller) SUPPLIES.
# =============================================================================

variable "project" {
  description = "Project short name, used as a prefix in every resource name (e.g. gmp)."
  type        = string
}

variable "env" {
  description = "Environment name: dev, staging or prod. Part of every resource name and tag."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block of the VPC. /16 = 65k addresses, far more than needed, but it is the conventional size and costs nothing."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnets" {
  description = <<-EOT
    Map of availability zone -> subnet CIDR. One subnet per AZ.

    The AZ name is the map KEY, which means it is also the for_each key and
    therefore part of each subnet's Terraform address:
      aws_subnet.public["eu-west-3a"]

    Consequence: reordering this map never destroys a subnet, unlike using
    count with a list where removing the first element renumbers everything
    after it. This is the single most important reason to prefer for_each.
  EOT
  type        = map(string)

  default = {
    "eu-west-3a" = "10.0.1.0/24"
    "eu-west-3b" = "10.0.2.0/24"
    "eu-west-3c" = "10.0.3.0/24"
  }

  validation {
    condition     = length(var.public_subnets) >= 1
    error_message = "At least one public subnet is required."
  }
}

variable "admin_cidr" {
  description = <<-EOT
    Your own public IP in CIDR form, e.g. "82.65.12.34/32".
    The ONLY address allowed to reach SSH (22), the k3s API (6443) and the
    NodePort range. Never set this to 0.0.0.0/0.

    Find yours with: curl -s https://checkip.amazonaws.com
    Note it changes if your ISP gives you a dynamic IP — re-apply when it does.
  EOT
  type        = string

  validation {
    condition     = can(cidrnetmask(var.admin_cidr))
    error_message = "admin_cidr must be a valid CIDR block, for example 82.65.12.34/32."
  }

  validation {
    condition     = var.admin_cidr != "0.0.0.0/0"
    error_message = "admin_cidr must not be 0.0.0.0/0 — that exposes SSH and the k3s API to the entire internet."
  }
}

variable "allow_http_from_internet" {
  description = <<-EOT
    Open 80/443 to 0.0.0.0/0 on the nodes.
    Leave false in Phase 1: you reach the app through the NodePort range from
    your own IP. Flip to true in Phase 2/3 once a real ingress controller is
    in front and you want the demo publicly reachable.
  EOT
  type        = bool
  default     = false
}

variable "tags" {
  description = "Extra tags merged into every resource created by this module."
  type        = map(string)
  default     = {}
}
