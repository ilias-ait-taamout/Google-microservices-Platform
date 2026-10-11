# =============================================================================
# modules/compute — the k3s cluster itself
# =============================================================================
#   eu-west-3a  ->  server   (m7i-flex.large, 8 GiB)  k3s control plane
#   eu-west-3b  ->  agent-1  (c7i-flex.large, 4 GiB)  worker
#   eu-west-3c  ->  agent-2  (c7i-flex.large, 4 GiB)  worker
#
# Nodes install themselves at first boot via user_data. No Ansible, no manual
# SSH steps: destroy the cluster and `terraform apply` rebuilds it identically.
# =============================================================================

locals {
  name_prefix = "${var.project}-${var.env}"

  tags = merge(
    {
      Project     = var.project
      Environment = var.env
      ManagedBy   = "terraform"
      Module      = "compute"
    },
    var.tags
  )

  # AZs sorted so placement is deterministic: the server always lands in the
  # first AZ, agents in the ones after it. Without sort(), map ordering could
  # move a node to a different AZ on a later apply — which means destroying
  # and recreating it.
  azs = sort(keys(var.subnet_ids))

  server_az = local.azs[0]
  agent_azs = slice(local.azs, 1, var.agent_count + 1)

  # agent-1 -> eu-west-3b, agent-2 -> eu-west-3c
  agents = { for idx, az in local.agent_azs : "agent-${idx + 1}" => az }

  # Use the supplied token, or the generated one.
  k3s_token = coalesce(var.k3s_token, random_password.k3s_token.result)

  key_pair_name = var.existing_key_pair_name != null ? var.existing_key_pair_name : aws_key_pair.this[0].key_name
}

# -----------------------------------------------------------------------------
# Cluster join token
# -----------------------------------------------------------------------------
# Alphanumeric only: this string is interpolated into a shell command line in
# the bootstrap script, and special characters there are a quoting bug waiting
# to happen.
resource "random_password" "k3s_token" {
  length  = 48
  special = false
}

# -----------------------------------------------------------------------------
# Ubuntu AMI lookup
# -----------------------------------------------------------------------------
# A `data` source READS existing AWS state — it creates nothing.
#
# Never hardcode an AMI ID. They are region-specific and get deprecated, so a
# hardcoded ID is a build that works today and fails in six months.
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical's official AWS account ID

  filter {
    name   = "name"
    values = [var.ubuntu_ami_name_filter]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"] # m7i-flex and c7i-flex are Intel
  }
}

# -----------------------------------------------------------------------------
# SSH key pair
# -----------------------------------------------------------------------------
# count = 0 when you supplied an existing key pair name, 1 when Terraform
# should create one. Only the PUBLIC key is read — the private half stays on
# your machine and never enters state.
resource "aws_key_pair" "this" {
  count = var.existing_key_pair_name == null ? 1 : 0

  key_name   = "${local.name_prefix}-key"
  public_key = file(pathexpand(var.ssh_public_key_path))

  tags = merge(local.tags, { Name = "${local.name_prefix}-key" })
}

# -----------------------------------------------------------------------------
# Control plane
# -----------------------------------------------------------------------------
resource "aws_instance" "server" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = var.server_instance_type
  subnet_id     = var.subnet_ids[local.server_az]
  key_name      = local.key_pair_name

  vpc_security_group_ids = [var.security_group_id]

  # Rendered at plan time and handed to cloud-init. Runs once, at first boot.
  # Changing this script REPLACES the instance — that is intentional: the node
  # is immutable, you rebuild rather than patch it in place.
  user_data = templatefile("${path.module}/templates/control-plane.sh.tftpl", {
    k3s_version     = var.k3s_version
    k3s_token       = local.k3s_token
    node_name       = "${local.name_prefix}-server"
    disable_traefik = var.disable_traefik
  })

  root_block_device {
    volume_size           = var.root_volume_size
    volume_type           = "gp3" # gp3 is cheaper and faster than gp2. Never use gp2.
    encrypted             = true
    delete_on_termination = true
  }

  # IMDSv2 required. Blocks the SSRF-to-credential-theft path that IMDSv1
  # allows, and it is the first thing a CIS benchmark or Checkov checks for.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2 # 2 so containers can still reach IMDS
  }

  tags = merge(local.tags, {
    Name               = "${local.name_prefix}-server"
    Role               = "control-plane"
    "k3s.io/node-role" = "server"
  })
}

# -----------------------------------------------------------------------------
# Workers
# -----------------------------------------------------------------------------
resource "aws_instance" "agent" {
  for_each = local.agents

  ami           = data.aws_ami.ubuntu.id
  instance_type = var.agent_instance_type
  subnet_id     = var.subnet_ids[each.value]
  key_name      = local.key_pair_name

  vpc_security_group_ids = [var.security_group_id]

  user_data = templatefile("${path.module}/templates/worker.sh.tftpl", {
    k3s_version = var.k3s_version
    k3s_token   = local.k3s_token
    node_name   = "${local.name_prefix}-${each.key}"

    # Referencing the server's private IP creates an implicit dependency:
    # Terraform will not start an agent until the server exists. It does NOT
    # guarantee k3s has finished installing there — that is why the worker
    # script waits for port 6443 before trying to join.
    server_ip = aws_instance.server.private_ip
  })

  root_block_device {
    volume_size           = var.root_volume_size
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  tags = merge(local.tags, {
    Name               = "${local.name_prefix}-${each.key}"
    Role               = "worker"
    "k3s.io/node-role" = "agent"
  })
}
