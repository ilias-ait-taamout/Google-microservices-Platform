.PHONY: init plan up down fmt validate

init:
	terraform init

fmt:
	terraform fmt -recursive

validate: fmt
	terraform validate

plan: init validate
	terraform plan

up: plan
	terraform apply

down:
	terraform destroy
