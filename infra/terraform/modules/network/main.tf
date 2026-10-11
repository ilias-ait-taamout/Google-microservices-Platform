# =============================================================================
# modules/network — network layer for the k3s cluster
# =============================================================================
# What this builds:
#
#   VPC 10.0.0.0/16
#    ├── Internet Gateway
#    ├── public subnet 10.0.1.0/24  (eu-west-3a)  -> k3s server
#    ├── public subnet 10.0.2.0/24  (eu-west-3b)  -> k3s agent 1
#    ├── public subnet 10.0.3.0/24  (eu-west-3c)  -> k3s agent 2
#    ├── one route table  0.0.0.0/0 -> IGW, associated to all three
#    └── security group "nodes"     -> attached to all three EC2s
#
# Deliberately NO private subnets and NO NAT gateway. A NAT gateway is ~32
# EUR/month EACH (so ~96 EUR for three AZs) and buys nothing here: the nodes
# need outbound internet for image pulls, and you reach them directly by SSH.
# Public subnets + a tight security group give the same result for 0 EUR.
# =============================================================================

locals {
  name_prefix = "${var.project}-${var.env}"

  tags = merge(
    {
      Project     = var.project
      Environment = var.env
      ManagedBy   = "terraform"
      Module      = "network"
    },
    var.tags
  )
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.tags, { Name = "${local.name_prefix}-vpc" })

}
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, { Name = "${local.name_prefix}-igw" })
}
resource "aws_subnet" "public" {
  for_each = var.public_subnets

  vpc_id            = aws_vpc.this.id
  availability_zone = each.key
  cidr_block        = each.value

  map_public_ip_on_launch = true

  tags = merge(local.tags, {
    Name = "${local.name_prefix}-public-${each.key}"

    # Standard Kubernetes tag. k3s does not read it, but the AWS cloud
    # controller and the AWS Load Balancer Controller do — and you will want
    # that in Phase 2/3 when a real LoadBalancer replaces NodePort.
    "kubernetes.io/role/elb" = "1"
  })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = merge(local.tags, { Name = "${local.name_prefix}-public-rt" })
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "nodes" {
  name_prefix = "${local.name_prefix}-nodes-"
  description = "k3s server and agents"
  vpc_id      = aws_vpc.this.id

  tags = merge(local.tags, { Name = "${local.name_prefix}-nodes-sg" })

  # This SG is referenced by EC2 instances, so a replacement must exist before
  # the old one is destroyed, otherwise Terraform deadlocks on updates.
  lifecycle {
    create_before_destroy = true
  }
}

# --- Inbound from YOU --------------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "ssh_from_admin" {
  security_group_id = aws_security_group.nodes.id
  description       = "SSH from admin workstation"
  cidr_ipv4         = var.admin_cidr
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "k3s_api_from_admin" {
  security_group_id = aws_security_group.nodes.id
  description       = "Kubernetes API server - kubectl from admin workstation"
  cidr_ipv4         = var.admin_cidr
  from_port         = 6443
  to_port           = 6443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "nodeport_from_admin" {
  security_group_id = aws_security_group.nodes.id
  description       = "NodePort range - reaching Online Boutique before an ingress exists"
  cidr_ipv4         = var.admin_cidr
  from_port         = 30000
  to_port           = 32767
  ip_protocol       = "tcp"
}

# --- Inbound between the cluster nodes ---------------------------------------
#
# DECISION: allow ALL traffic between members of this security group, rather
# than enumerating individual ports.
#
# The ports k3s actually needs node-to-node are:
#   6443/tcp        API server (agents joining and staying connected)
#   10250/tcp       kubelet API - metrics-server, kubectl logs, kubectl exec
#   8472/udp        flannel VXLAN, the pod network overlay  <-- UDP, not TCP
#   2379-2380/tcp   etcd, ONLY with multiple servers (embedded HA).
#                   You run one server, so k3s uses SQLite and these are unused.
#
# Enumerating those four works today and breaks in Phase 5: Prometheus will
# scrape node-exporter on 9100, kube-state-metrics on 8080, and anything else
# a future chart decides to expose on a host port. Each becomes a silent
# timeout that costs an evening to diagnose.
#
# The security tradeoff is small and bounded: this rule only admits traffic
# from instances already inside this SG — no CIDR, no internet. AWS's own EKS
# managed node group SG does exactly the same thing for the same reason.
# Real pod-to-pod isolation belongs one layer up, in Kubernetes
# NetworkPolicies, which is Phase 4.
resource "aws_vpc_security_group_ingress_rule" "all_from_nodes" {
  security_group_id            = aws_security_group.nodes.id
  description                  = "All traffic between k3s nodes - see decision note in main.tf"
  referenced_security_group_id = aws_security_group.nodes.id
  ip_protocol                  = "-1" # -1 = every protocol, every port
}

# --- Optional: public HTTP/HTTPS ---------------------------------------------
# count = 0 or 1. Off in Phase 1; flip the variable in Phase 2/3 when a real
# ingress controller is in front of the app.
resource "aws_vpc_security_group_ingress_rule" "http_from_internet" {
  count = var.allow_http_from_internet ? 1 : 0

  security_group_id = aws_security_group.nodes.id
  description       = "HTTP from the internet"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "https_from_internet" {
  count = var.allow_http_from_internet ? 1 : 0

  security_group_id = aws_security_group.nodes.id
  description       = "HTTPS from the internet"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

# --- Outbound ----------------------------------------------------------------
# Wide open on purpose: nodes must reach get.k3s.io, apt mirrors, DockerHub and
# the AWS APIs. Restricting egress is a Phase 4 exercise, not a Phase 1 one.
resource "aws_vpc_security_group_egress_rule" "all_outbound" {
  security_group_id = aws_security_group.nodes.id
  description       = "Allow all outbound - image pulls, package installs, AWS APIs"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}