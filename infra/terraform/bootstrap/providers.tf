terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # State local: ce module crée le backend distant utilisé par les autres
  # modules (envs/dev). Il ne peut donc pas s'appuyer dessus lui-même.
}

provider "aws" {
  region = var.region
}
