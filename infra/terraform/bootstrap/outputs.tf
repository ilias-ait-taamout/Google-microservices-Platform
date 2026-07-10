output "state_bucket_name" {
  description = "Nom du bucket S3 contenant le state Terraform distant"
  value       = aws_s3_bucket.terraform_state.id
}

output "state_bucket_arn" {
  description = "ARN du bucket S3 de state"
  value       = aws_s3_bucket.terraform_state.arn
}

output "lock_table_name" {
  description = "Nom de la table DynamoDB utilisée pour le lock du state"
  value       = aws_dynamodb_table.terraform_lock.name
}
