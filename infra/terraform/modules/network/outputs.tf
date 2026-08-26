# =============================================================================
# modules/network — OUTPUTS
# =============================================================================
# A module's outputs are its public API. envs/dev/main.tf reads these and feeds
# them into the compute module:
#
#   module "compute" {
#     subnet_ids        = module.network.public_subnet_ids
#     security_group_id = module.network.node_security_group_id
#   }
#
# Anything not exported here is invisible to the caller.
# =============================================================================

output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "CIDR of the VPC. Needed later for NetworkPolicies and CI allowlists."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = <<-EOT
    Map of availability zone -> subnet ID, e.g.
      { "eu-west-3a" = "subnet-0abc...", "eu-west-3b" = "subnet-0def..." }

    A map rather than a list on purpose: the compute module places a named
    node in a named AZ. With a list you would be indexing by position, and
    node placement would silently shift if the list ever reordered.
  EOT
  value       = { for az, subnet in aws_subnet.public : az => subnet.id }
}

output "availability_zones" {
  description = "Sorted list of the AZs in use. Handy for round-robin placement in the compute module."
  value       = sort(keys(aws_subnet.public))
}

output "node_security_group_id" {
  description = "ID of the security group attached to every k3s node."
  value       = aws_security_group.nodes.id
}
