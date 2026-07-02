# Copyright 2022 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Definition of local variables
locals {
  cluster_name = var.name
}

data "aws_availability_zones" "available" {
  state = "available"
}

# Create the VPC that will house the EKS cluster
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.name}-vpc"
  cidr = var.vpc_cidr

  azs             = slice(data.aws_availability_zones.available.names, 0, 3)
  private_subnets = [for k in range(3) : cidrsubnet(var.vpc_cidr, 4, k)]
  public_subnets  = [for k in range(3) : cidrsubnet(var.vpc_cidr, 4, k + 3)]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }
}

# Create EKS cluster on Fargate (serverless, no node management, mirroring GKE Autopilot)
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = local.cluster_name
  cluster_version = var.cluster_version

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.private_subnets

  cluster_endpoint_public_access = true

  fargate_profiles = {
    default = {
      name = "default"
      selectors = [
        { namespace = var.namespace },
        { namespace = "kube-system" }
      ]
    }
  }

  # coredns must be told to run on Fargate since this cluster has no EC2 node group
  cluster_addons = {
    coredns = {
      configuration_values = jsonencode({
        computeType = "Fargate"
      })
    }
    kube-proxy = {}
    vpc-cni    = {}
  }
}

# Get credentials for cluster
resource "null_resource" "kubeconfig" {
  provisioner "local-exec" {
    interpreter = ["bash", "-exc"]
    command     = "aws eks update-kubeconfig --name ${local.cluster_name} --region ${var.region}"
  }

  depends_on = [
    module.eks
  ]
}

# Apply YAML kubernetes-manifest configurations
resource "null_resource" "apply_deployment" {
  provisioner "local-exec" {
    interpreter = ["bash", "-exc"]
    command     = "kubectl apply -k ${var.filepath_manifest} -n ${var.namespace}"
  }

  depends_on = [
    null_resource.kubeconfig
  ]
}

# Wait condition for all Pods to be ready before finishing
resource "null_resource" "wait_conditions" {
  provisioner "local-exec" {
    interpreter = ["bash", "-exc"]
    command     = <<-EOT
    kubectl wait --for=condition=ready pods --all -n ${var.namespace} --timeout=280s
    EOT
  }

  depends_on = [
    resource.null_resource.apply_deployment
  ]
}
