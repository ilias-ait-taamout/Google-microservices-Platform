# =============================================================================
# modules/compute — provider requirements
# =============================================================================
# A module declares which providers it needs, but NOT how they are configured.
# Configuration (region, profile, default_tags) is the root module's job —
# envs/dev/providers.tf. A child module that configures its own provider is a
# module that cannot be reused across environments.
# =============================================================================

terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
