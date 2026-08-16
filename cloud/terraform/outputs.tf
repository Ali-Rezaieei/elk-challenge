# ---------------------------------------------------------------------------
# Non-sensitive outputs. Secrets (passwords) are owned by Ansible and never
# appear in Terraform state or output.
# ---------------------------------------------------------------------------

output "server_ipv4" {
  description = "Public IPv4 of the server."
  value       = hcloud_server.elk.ipv4_address
}

output "https_url" {
  description = "The single entry point to the stack."
  value       = "https://${hcloud_server.elk.ipv4_address}/"
}

output "server_name" {
  description = "Server name, for the API listing and troubleshooting."
  value       = hcloud_server.elk.name
}

output "generated_inventory" {
  description = "Path to the Ansible inventory rendered from state."
  value       = abspath(var.generated_inventory_path)
}
