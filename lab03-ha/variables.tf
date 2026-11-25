variable "region" {
  description = "Región de AWS"
  type        = string
  default     = "us-east-2"
}

variable "azs" {
  description = "Zonas de disponibilidad a usar"
  type        = list(string)
  default     = ["us-east-2a", "us-east-2b"]
}

variable "instance_type" {
  description = "Tipo de instancia EC2"
  type        = string
  default     = "t3.micro"
}

variable "cantidad_servidores" {
  description = "Cuántos servidores mantiene el Auto Scaling Group"
  type        = number
  default     = 2
}