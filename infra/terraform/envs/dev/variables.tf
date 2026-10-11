# =============================================================================
# envs/dev — INPUTS
# =============================================================================
# Non-secret dev values keep their defaults here so the environment is
# reproducible from Git alone.
#
# admin_cidr has NO default — it is your home IP, it changes, and it must not
# live in a committed file. It goes in terraform.tfvars, which .gitignore
# excludes.
# =============================================================================

variable "project" {
  description = "Project short name, prefix for every resource name."
  type        = string
  default     = "gmp"
}

variable "env" {
  description = "Environment name. Must match the backend key prefix (dev/)."
  type        = string
  default     = "dev"
}

variable "aws_region" {
  description = "Region resources are created in."
  type        = string
  default     = "eu-west-3"
}

variable "aws_profile" {
  description = "Named AWS CLI profile. Must match the profile in backend.tf. Check yours with: aws configure list-profiles"
  type        = string
  default     = "terraform-mgp"
}

# --- Network -----------------------------------------------------------------

variable "vpc_cidr" {
  description = "CIDR of the dev VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnets" {
  description = "Availability zone -> subnet CIDR. One per AZ, three total."
  type        = map(string)

  default = {
    "eu-west-3a" = "10.0.1.0/24"
    "eu-west-3b" = "10.0.2.0/24"
    "eu-west-3c" = "10.0.3.0/24"
  }
}

variable "admin_cidr" {
  description = "Your public IP as a /32. REQUIRED — set it in terraform.tfvars. Get it with: curl -s https://checkip.amazonaws.com"
  type        = string
}

# --- Compute -----------------------------------------------------------------

variable "server_instance_type" {
  description = "Control plane instance type. m7i-flex.large = 2 vCPU / 8 GiB."
  type        = string
  default     = "m7i-flex.large"
}

variable "agent_instance_type" {
  description = "Worker instance type. c7i-flex.large = 2 vCPU / 4 GiB."
  type        = string
  default     = "c7i-flex.large"
}

variable "agent_count" {
  description = "Number of workers."
  type        = number
  default     = 2
}

variable "root_volume_size" {
  description = "Root EBS volume per node, in GiB."
  type        = number
  default     = 30
}

variable "k3s_version" {
  description = "Pinned k3s version. Releases: https://github.com/k3s-io/k3s/releases"
  type        = string
  default     = "v1.31.5+k3s1"
}

# --- SSH ---------------------------------------------------------------------
# Set EXACTLY ONE of these in terraform.tfvars.

variable "existing_key_pair_name" {
  description = "Name of an EC2 key pair that already exists in eu-west-3. Null means Terraform creates one from ssh_public_key_path."
  type        = string
  default     = null
}

variable "ssh_public_key_path" {
  description = "Path to your PUBLIC key, used only when existing_key_pair_name is null. No key yet? ssh-keygen -t ed25519 -C \"gmp-dev\""
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}
