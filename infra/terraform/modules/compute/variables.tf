# =============================================================================
# modules/compute — INPUTS
# =============================================================================

variable "project" {
  description = "Project short name, prefix for every resource name."
  type        = string
}

variable "env" {
  description = "Environment name: dev, staging or prod."
  type        = string
}

# --- Placement (comes from the network module) -------------------------------

variable "subnet_ids" {
  description = "Map of availability zone -> subnet ID, straight from module.network.public_subnet_ids."
  type        = map(string)

  validation {
    condition     = length(var.subnet_ids) >= 3
    error_message = "Three subnets are required: one for the server, one per agent."
  }
}

variable "security_group_id" {
  description = "ID of the node security group, from module.network.node_security_group_id."
  type        = string
}

# --- Sizing ------------------------------------------------------------------

variable "server_instance_type" {
  description = "Instance type for the k3s server (control plane). m7i-flex.large = 2 vCPU / 8 GiB."
  type        = string
  default     = "m7i-flex.large"
}

variable "agent_instance_type" {
  description = "Instance type for each k3s agent (worker). c7i-flex.large = 2 vCPU / 4 GiB."
  type        = string
  default     = "c7i-flex.large"
}

variable "agent_count" {
  description = "Number of worker nodes. Must not exceed the number of subnets minus one."
  type        = number
  default     = 2
}

variable "root_volume_size" {
  description = "Root EBS volume size in GiB. 30 leaves room for container images; the 11 Online Boutique images alone are several GiB."
  type        = number
  default     = 30
}

# --- Operating system --------------------------------------------------------

variable "ubuntu_ami_name_filter" {
  description = <<-EOT
    Name pattern for the Ubuntu AMI. The trailing * matches the build date, so
    this always resolves to the newest published image.

    24.04 LTS (noble): ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*
    22.04 LTS (jammy): ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*
  EOT
  type        = string
  default     = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"
}

# --- SSH access --------------------------------------------------------------
# Set EXACTLY ONE of the two variables below.

variable "existing_key_pair_name" {
  description = <<-EOT
    Name of an EC2 key pair that already exists in eu-west-3.
    Leave null to have Terraform create one from ssh_public_key_path instead.
  EOT
  type        = string
  default     = null
}

variable "ssh_public_key_path" {
  description = <<-EOT
    Path to your PUBLIC key on this machine, e.g. "~/.ssh/id_ed25519.pub".
    Only used when existing_key_pair_name is null.

    Only the public half is ever read. The private key never touches Terraform,
    never enters state, and never goes near Git.

    No key yet? Generate one:
      ssh-keygen -t ed25519 -C "gmp-dev"
  EOT
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

# --- k3s ---------------------------------------------------------------------

variable "k3s_version" {
  description = <<-EOT
    Exact k3s version to install, e.g. "v1.31.5+k3s1". Pinned on purpose:
    an unpinned install means two nodes built a week apart can run different
    versions, which is exactly the kind of drift this project exists to prevent.

    Available versions: https://github.com/k3s-io/k3s/releases
  EOT
  type        = string
  default     = "v1.31.5+k3s1"
}

variable "k3s_token" {
  description = <<-EOT
    Shared secret agents use to join the cluster.
    Leave null and Terraform generates a random 48-character one.

    It lives in Terraform state either way — which is precisely why state sits
    in an encrypted S3 bucket and never in Git.
  EOT
  type        = string
  default     = null
  sensitive   = true
}

variable "disable_traefik" {
  description = "k3s ships Traefik as its default ingress. Disabled here because Phase 2/3 installs its own ingress; two ingress controllers fighting over port 80 is a bad first day."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Extra tags merged into every resource."
  type        = map(string)
  default     = {}
}
