# =============================================================================
# envs/dev — AWS provider
# =============================================================================
# The backend says WHERE STATE IS STORED.
# The provider says WHERE RESOURCES ARE CREATED.
# They are two different things and both happen to point at eu-west-3 here.
#
# Note there is no provider block in modules/network or modules/compute. A
# child module declares which providers it NEEDS (versions.tf) but never
# configures them — that is what lets the same module build any region.
# =============================================================================

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  # Merged into every resource this provider creates, automatically.
  # You never have to remember to tag anything by hand.
  default_tags {
    tags = {
      Project     = var.project
      Environment = var.env
      ManagedBy   = "terraform"
      Repository  = "Google-microservices-Platform"
    }
  }
}
