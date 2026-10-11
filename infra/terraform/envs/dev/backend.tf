terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~>6.0"
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