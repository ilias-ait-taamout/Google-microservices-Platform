# =============================================================================
# envs/dev — OUTPUTS
# =============================================================================
# Printed after every apply, and readable any time with `terraform output`.
# These are the values you actually use to work with the cluster.
# =============================================================================

output "cluster_endpoint" {
  description = "Kubernetes API endpoint."
  value       = "https://${module.compute.server_public_ip}:6443"
}

output "server_public_ip" {
  description = "Public IP of the control plane."
  value       = module.compute.server_public_ip
}

output "agent_public_ips" {
  description = "Public IP of each worker node."
  value       = module.compute.agent_public_ips
}

output "vpc_id" {
  description = "ID of the VPC."
  value       = module.network.vpc_id
}

output "all_instance_ids" {
  description = "Every instance ID in the cluster. Read by cluster.ps1 stop/start."
  value       = module.compute.all_instance_ids
}

output "ami_id" {
  description = "The Ubuntu AMI actually selected. Worth recording — it changes as Canonical publishes new builds."
  value       = module.compute.ami_id
}

output "next_steps" {
  description = "What to do once apply finishes."
  value       = <<-EOT

    ----------------------------------------------------------------
      Cluster is provisioning. k3s needs ~3 min after apply returns.
    ----------------------------------------------------------------

    1. Fetch the kubeconfig:
       .\cluster.ps1 kubeconfig

    2. Point kubectl at it:
       $env:KUBECONFIG = "$PWD\kubeconfig-dev.yaml"

    3. Confirm all three nodes are Ready:
       kubectl get nodes -o wide

    If a node is missing, SSH in and read the bootstrap log:
       ssh ubuntu@${module.compute.server_public_ip}
       sudo tail -100 /var/log/k3s-bootstrap.log

    When you finish for the day:
       .\cluster.ps1 down

  EOT
}
