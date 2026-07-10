variable "region" {
  description = "Région AWS"
  type        = string
  default     = "eu-west-3"
}

variable "project_name" {
  description = "Nom du projet, utilisé comme préfixe pour les ressources"
  type        = string
  default     = "google-microservices-platform"
}

variable "environment" {
  description = "Environnement (dev, staging, prod...)"
  type        = string
  default     = "dev"
}
