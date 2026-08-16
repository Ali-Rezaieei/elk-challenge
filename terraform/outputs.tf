# ---------------------------------------------------------------------------
# Outputs are intentionally minimal and non-sensitive. Deploy-time secrets
# (passwords) are owned by Ansible and never surface in Terraform state or
# output. The URL is the one thing a human needs after apply.
# ---------------------------------------------------------------------------

output "https_url" {
  description = "The single entry point to the stack."
  value       = "https://localhost:${var.published_https_port}/"
}

output "elasticsearch_proxy_path" {
  description = "Elasticsearch is reachable only through the proxy, under /es/."
  value       = "https://localhost:${var.published_https_port}/es/"
}

output "generated_inventory" {
  description = "Path to the Ansible inventory rendered from state (the layer handover)."
  value       = abspath(var.generated_inventory_path)
}

output "container_names" {
  description = "Names of the created containers, for `docker logs`/troubleshooting."
  value = {
    elasticsearch = docker_container.elasticsearch.name
    kibana        = docker_container.kibana.name
    nginx         = docker_container.nginx.name
  }
}
