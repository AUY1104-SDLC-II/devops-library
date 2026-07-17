output "public_ip" {
  description = "IPv4 pública de la MV"
  value       = aws_instance.lab.public_ip
}

output "instance_id" {
  description = "ID de la instancia EC2"
  value       = aws_instance.lab.id
}

output "ssh_user" {
  description = "Usuario SSH en AMI Ubuntu oficial de Canonical"
  value       = "ubuntu"
}

output "ssh_hint" {
  description = "Comando SSH de referencia (la clave privada la tiene quien ejecutó el workflow)"
  value       = "ssh -i <tu-clave-privada.pem> ubuntu@${aws_instance.lab.public_ip}"
}
