# =============================================================================
# envs/dev — REMOTE STATE BACKEND
# =============================================================================
# This is the file that makes state live in S3 instead of on your laptop.
#
# Bucket "ilias-mgp-tfstate" was created by hand in the console. That is the
# normal, accepted exception to "everything in code": Terraform cannot create
# the bucket that stores its own state. Every OTHER resource in this project
# is created by Terraform.
#
# Note what is NOT here:
#   - no variables. Backend blocks are read before variables are evaluated,
#     so every value must be a literal string. This is a Terraform limitation,
#     not a style choice.
#   - no dynamodb_table. See the locking note at the bottom.
# =============================================================================

terraform {
  # 1.11+ : `use_lockfile` (S3-native locking) is generally available.
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  backend "s3" {
    bucket = "ilias-mgp-tfstate"

    # The path INSIDE the bucket. This is what separates environments:
    #   dev/terraform.tfstate
    #   staging/terraform.tfstate
    #   prod/terraform.tfstate
    # Same bucket, three independent state files. Changing this line is how
    # envs/staging and envs/prod will differ from this file.
    key = "dev/terraform.tfstate"

    region = "eu-west-3"

    # Named profile in ~/.aws/credentials.
    # CHANGE THIS if your profile is not called "terraform-mgp".
    # Check with: aws configure list-profiles
    profile = "terraform-mgp"

    # Encrypt the state object at rest (SSE-S3).
    encrypt = true

    # ---------------------------------------------------------------------
    # STATE LOCKING — S3-native, no DynamoDB
    # ---------------------------------------------------------------------
    # Terraform writes dev/terraform.tfstate.tflock and uses S3 conditional
    # writes to guarantee only one holder. If a second apply starts while
    # yours is running, it waits instead of corrupting the state.
    #
    # The old way was a DynamoDB table (`dynamodb_table = "terraform-lock"`).
    # That attribute is deprecated since Terraform 1.11 and slated for removal.
    # Your IAM policy still grants DynamoDB access for a terraform-lock table —
    # that grant is now unused and can be removed at the next policy cleanup.
    #
    # Requires s3:PutObject, s3:GetObject and s3:DeleteObject on
    # arn:aws:s3:::ilias-mgp-tfstate/*
    # ---------------------------------------------------------------------
    use_lockfile = true
  }
}
