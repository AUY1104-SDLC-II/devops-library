variable "aws_region" {
  type        = string
  description = "Región AWS (ej. us-east-1)"
}

variable "instance_type" {
  type        = string
  description = "Tipo de instancia EC2"
  default     = "t3.small"
}

variable "public_key" {
  type        = string
  description = "Clave pública SSH (una sola línea) para asociar a la instancia"
}

variable "ssh_cidr_ipv4" {
  type        = string
  description = "CIDR desde el que se permite SSH (0.0.0.0/0 solo laboratorio)"
  default     = "0.0.0.0/0"
}

variable "k8s_api_cidr_ipv4" {
  type        = string
  description = "CIDR desde el que se permite la API de Kubernetes/K3s (6443/tcp). kubectl desde tu PC necesita esto o un tunel SSH."
  default     = "0.0.0.0/0"
}

variable "k8s_nodeport_min" {
  type        = number
  description = "Puerto mínimo NodePort a abrir (académico)"
  default     = 30000
}

variable "k8s_nodeport_max" {
  type        = number
  description = "Puerto máximo NodePort a abrir (académico)"
  default     = 32767
}

variable "root_volume_size" {
  type        = number
  description = "GiB disco raiz. AWS Academy suele limitar tamano; 8 GiB suele pasar."
  default     = 8
}

variable "root_volume_type" {
  type        = string
  description = "gp2 suele estar permitido en Learner Lab; gp3 a veces tiene deny explicito."
  default     = "gp2"
}
