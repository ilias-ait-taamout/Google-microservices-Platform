

# Subnet group placing the ElastiCache node in the cluster's private subnets
resource "aws_elasticache_subnet_group" "redis-cart" {
  count      = var.elasticache ? 1 : 0
  name       = "redis-cart-subnet-group"
  subnet_ids = module.vpc.private_subnets
}

# Security group allowing the EKS cluster to reach the ElastiCache node on the Redis port
resource "aws_security_group" "redis-cart" {
  count  = var.elasticache ? 1 : 0
  name   = "redis-cart-sg"
  vpc_id = module.vpc.vpc_id

  ingress {
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Create the ElastiCache (redis) instance
resource "aws_elasticache_cluster" "redis-cart" {
  count = var.elasticache ? 1 : 0

  cluster_id         = "redis-cart"
  engine             = "redis"
  engine_version     = "7.0"
  node_type          = "cache.t3.micro"
  num_cache_nodes    = 1
  port               = 6379
  subnet_group_name  = aws_elasticache_subnet_group.redis-cart[0].name
  security_group_ids = [aws_security_group.redis-cart[0].id]
}

# Edit contents of Memorystore kustomization.yaml file to target new ElastiCache (redis) instance
resource "null_resource" "kustomization-update" {
  provisioner "local-exec" {
    interpreter = ["bash", "-exc"]
    command     = "sed -i \"s/REDIS_CONNECTION_STRING/${aws_elasticache_cluster.redis-cart[0].cache_nodes[0].address}:${aws_elasticache_cluster.redis-cart[0].port}/g\" ../kustomize/components/memorystore/kustomization.yaml"
  }

  # count specifies the number of instances to create;
  # if var.elasticache is true then the resource is enabled
  count = var.elasticache ? 1 : 0

  depends_on = [
    resource.aws_elasticache_cluster.redis-cart
  ]
}
