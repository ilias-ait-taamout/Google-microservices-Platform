# =============================================================================
# envs/dev — cost control and everyday commands
# =============================================================================
# Three c7i/m7i-flex instances left running 24/7 cost roughly 180-200 EUR/month.
# Use `make stop` at the end of every session. Use `make down` when you are
# finished with a phase.
#
#   make stop   halt the EC2s. Disks and cluster state survive.
#               Cost drops to EBS only (~2 EUR/week for 90 GiB).
#   make start  boot them again. k3s comes back by itself; public IPs CHANGE.
#   make down   destroy everything. Cheapest. ~10 min to rebuild with `make up`.
#
# Run these from infra/terraform/envs/dev.
# On Windows, use Git Bash or WSL — nmake will not work.
# =============================================================================

PROFILE ?= terraform-mgp
REGION  ?= eu-west-3

.PHONY: help init fmt validate plan up down stop start status kubeconfig nodes ip

help:
	@echo "init       terraform init"
	@echo "fmt        format all .tf files in the repo"
	@echo "validate   syntax + type check"
	@echo "plan       show what would change"
	@echo "up         apply (creates the cluster)"
	@echo "down       destroy everything"
	@echo "stop       halt the EC2s, keep the disks   <- end of every session"
	@echo "start      boot them again (public IPs change)"
	@echo "status     instance states"
	@echo "kubeconfig fetch kubeconfig from the control plane"
	@echo "nodes      kubectl get nodes -o wide"
	@echo "ip         update admin_cidr to your current public IP"

init:
	terraform init

fmt:
	terraform fmt -recursive ../../

validate:
	terraform validate

plan:
	terraform plan

up:
	terraform apply

down:
	terraform destroy

# --- Cost control -------------------------------------------------------------
# Reads instance IDs straight out of Terraform state, so it always targets this
# environment's nodes and nothing else in the account.

stop:
	@echo "Stopping cluster instances..."
	@aws ec2 stop-instances --profile $(PROFILE) --region $(REGION) \
		--instance-ids $$(terraform output -json all_instance_ids | tr -d '[]"' | tr ',' ' ') \
		--query 'StoppingInstances[].InstanceId' --output text
	@echo "Stopped. You are now paying for EBS only."

start:
	@echo "Starting cluster instances..."
	@aws ec2 start-instances --profile $(PROFILE) --region $(REGION) \
		--instance-ids $$(terraform output -json all_instance_ids | tr -d '[]"' | tr ',' ' ') \
		--query 'StartingInstances[].InstanceId' --output text
	@echo ""
	@echo "Public IPs have CHANGED. Wait ~60s, then run: make kubeconfig"

status:
	@aws ec2 describe-instances --profile $(PROFILE) --region $(REGION) \
		--filters "Name=tag:Project,Values=gmp" "Name=tag:Environment,Values=dev" \
		--query 'Reservations[].Instances[].{Name:Tags[?Key==`Name`]|[0].Value,State:State.Name,IP:PublicIpAddress}' \
		--output table

# --- Cluster access -----------------------------------------------------------

kubeconfig:
	@IP=$$(aws ec2 describe-instances --profile $(PROFILE) --region $(REGION) \
		--filters "Name=tag:Name,Values=gmp-dev-server" "Name=instance-state-name,Values=running" \
		--query 'Reservations[0].Instances[0].PublicIpAddress' --output text); \
	echo "control plane: $$IP"; \
	scp -o StrictHostKeyChecking=no ubuntu@$$IP:~/.kube/config ./kubeconfig-dev.yaml; \
	sed -i "s|https://.*:6443|https://$$IP:6443|" ./kubeconfig-dev.yaml; \
	echo "written to ./kubeconfig-dev.yaml"; \
	echo "export KUBECONFIG=$$PWD/kubeconfig-dev.yaml"

nodes:
	@KUBECONFIG=./kubeconfig-dev.yaml kubectl get nodes -o wide

# Home IP changed and everything started timing out? Run this.
ip:
	@NEW=$$(curl -s https://checkip.amazonaws.com); \
	echo "your public IP is $$NEW"; \
	sed -i "s|^admin_cidr.*|admin_cidr = \"$$NEW/32\"|" terraform.tfvars; \
	echo "terraform.tfvars updated - now run: make up"
