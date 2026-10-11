# =============================================================================
# envs/dev — the root module. THIS is where you run terraform.
# =============================================================================
# It contains no resources of its own. Its entire job is to call the two child
# modules with dev-specific values and wire one's outputs into the other's
# inputs.
#
# envs/staging and envs/prod will be near-copies of this file: same modules,
# different CIDRs, different instance sizes, different backend key.
# =============================================================================

module "network" {
  source = "../../modules/network"

  project = var.project
  env     = var.env

  vpc_cidr       = var.vpc_cidr
  public_subnets = var.public_subnets
  admin_cidr     = var.admin_cidr

  # Phase 1: reach the app through NodePort from your own IP only.
  # Flip to true in Phase 2/3 once a real ingress controller is in front.
  allow_http_from_internet = false
}

module "compute" {
  source = "../../modules/compute"

  project = var.project
  env     = var.env

  # ---------------------------------------------------------------------------
  # THE WIRING. This is the entire mechanism by which modules connect:
  # an output of one becomes an input of the other.
  #
  # It also builds the dependency graph. Terraform reads these references and
  # works out on its own that the VPC, subnets and security group must exist
  # before any instance is launched. You never write depends_on for this.
  # ---------------------------------------------------------------------------
  subnet_ids        = module.network.public_subnet_ids
  security_group_id = module.network.node_security_group_id

  server_instance_type = var.server_instance_type
  agent_instance_type  = var.agent_instance_type
  agent_count          = var.agent_count
  root_volume_size     = var.root_volume_size

  k3s_version = var.k3s_version

  # Set ONE of these two in terraform.tfvars.
  existing_key_pair_name = var.existing_key_pair_name
  ssh_public_key_path    = var.ssh_public_key_path
}
