# =============================================================================
# modules/compute — OUTPUTS
# =============================================================================

output "server_public_ip" {
  description = "Public IP of the k3s control plane. This is what kubectl talks to."
  value       = aws_instance.server.public_ip
}

output "server_private_ip" {
  description = "Private IP of the control plane, used by the agents to join."
  value       = aws_instance.server.private_ip
}

output "server_id" {
  description = "EC2 instance ID of the control plane."
  value       = aws_instance.server.id
}

output "agent_public_ips" {
  description = "Map of agent name -> public IP."
  value       = { for name, inst in aws_instance.agent : name => inst.public_ip }
}

output "agent_ids" {
  description = "Map of agent name -> EC2 instance ID."
  value       = { for name, inst in aws_instance.agent : name => inst.id }
}

output "all_instance_ids" {
  description = "Every instance ID in the cluster, for start/stop scripting."
  value       = concat([aws_instance.server.id], [for inst in aws_instance.agent : inst.id])
}

output "ami_id" {
  description = "The Ubuntu AMI actually selected. Worth recording — it changes as Canonical publishes new builds."
  value       = data.aws_ami.ubuntu.id
}

output "ssh_command" {
  description = "Ready-to-paste SSH command for the control plane."
  value       = "ssh ubuntu@${aws_instance.server.public_ip}"
}

output "fetch_kubeconfig_command" {
  description = "Copies the cluster's kubeconfig to your machine, already pointing at the public IP."
  value       = "scp ubuntu@${aws_instance.server.public_ip}:~/.kube/config ./kubeconfig-${var.env}.yaml"
}

output "k3s_token" {
  description = "The cluster join token. Sensitive: reveal with `terraform output -raw k3s_token`."
  value       = local.k3s_token
  sensitive   = true
}
