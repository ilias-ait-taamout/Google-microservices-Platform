<!-- Copyright 2022 Google LLC

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License. -->

# Use Terraform to deploy Online Boutique on an EKS cluster

This page walks you through the steps required to deploy the [Online Boutique](https://github.com/GoogleCloudPlatform/microservices-demo) sample application on an [Amazon Elastic Kubernetes Service (EKS)](https://aws.amazon.com/eks/) cluster using Terraform.

## Prerequisites

1. An [AWS account](https://aws.amazon.com/) with credentials configured locally (e.g. via `aws configure` or the `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` environment variables) and sufficient permissions to create VPCs, EKS clusters, and ElastiCache resources.
1. The [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) and [kubectl](https://kubernetes.io/docs/tasks/tools/#kubectl) installed locally.

## Deploy the sample application

1. Clone the Github repository.

    ```bash
    git clone https://github.com/GoogleCloudPlatform/microservices-demo.git
    ```

1. Move into the `terraform/` directory which contains the Terraform installation scripts.

    ```bash
    cd microservices-demo/terraform
    ```

1. (Optional) Open the `terraform.tfvars` file and adjust the `region` variable to the AWS region you want the cluster deployed to.

1. (Optional) If you want to provision an [AWS ElastiCache (Redis)](https://aws.amazon.com/elasticache/) instance, you can change the value of `elasticache = false` to `elasticache = true` in this `terraform.tfvars` file.

1. Initialize Terraform.

    ```bash
    terraform init
    ```

1. See what resources will be created.

    ```bash
    terraform plan
    ```

1. Create the resources and deploy the sample.

    ```bash
    terraform apply
    ```

    1. If there is a confirmation prompt, type `yes` and hit Enter/Return.

    Note: This step can take about 15 minutes. Do not interrupt the process.

Once the Terraform script has finished, you can locate the frontend's external address to access the sample application.

- Option 1:

    ```bash
    kubectl get service frontend-external | awk '{print $4}'
    ```

- Option 2: On the AWS Console, navigate to "EKS" and then to the cluster's workloads, or inspect the Load Balancer created for the "frontend-external" Service under "EC2" > "Load Balancers".

## Clean up

To avoid incurring charges to your AWS account for the resources used in this sample application:

1. Navigate to the `terraform/` directory.

1. Run the following command:

   ```bash
   terraform destroy
   ```

   1. If there is a confirmation prompt, type `yes` and hit Enter/Return.
