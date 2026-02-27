output "mx_primary_fqdn" {
  description = "Primary MX record FQDN"
  value       = aws_route53_record.mx_primary.fqdn
}

output "mx_thread_fqdn" {
  description = "Thread subdomain MX record FQDN"
  value       = aws_route53_record.mx_thread.fqdn
}
