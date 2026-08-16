# ---------------------------------------------------------------------------
# All tunables live here. Every variable has a description and a working
# default, so an untouched `terraform apply` produces a valid stack. Nothing is
# a buried magic number: if a reviewer wants to change a port, a subnet, or a
# version, there is exactly one obvious place to do it.
# ---------------------------------------------------------------------------

variable "docker_host" {
  description = "Docker Engine endpoint. Default suits Linux and Docker Desktop; override for a remote/rootless socket."
  type        = string
  # unix:///var/run/docker.sock is correct for Linux and Docker Desktop.
  # Rootless Docker users override this with unix://$XDG_RUNTIME_DIR/docker.sock.
  default = "unix:///var/run/docker.sock"
}

variable "project_prefix" {
  description = "Prefix applied to every Docker object so the stack is greppable and teardown can be scoped precisely."
  type        = string
  default     = "elk-local"

  validation {
    # Docker object names must be DNS-ish; enforce it early with a clear error
    # rather than letting the daemon reject it mid-apply.
    condition     = can(regex("^[a-z0-9][a-z0-9_-]{1,30}$", var.project_prefix))
    error_message = "project_prefix must be 2-31 chars of [a-z0-9_-] and start alphanumeric."
  }
}

variable "elastic_stack_version" {
  description = "Elasticsearch AND Kibana image tag. They MUST be identical; a mixed-version stack is unsupported by Elastic."
  type        = string
  default     = "8.15.3"
}

variable "nginx_image" {
  description = "Reverse-proxy image. Uses the *unprivileged* nginx image so the edge runs as a non-root user out of the box."
  type        = string
  # -unprivileged runs as uid 101 and binds high ports, letting us drop all
  # Linux capabilities without NET_BIND_SERVICE gymnastics.
  default = "nginxinc/nginx-unprivileged:1.27.2-alpine"
}

variable "published_https_port" {
  description = "The single TCP port published to the host. This is the ONLY way into the stack from outside the Docker network."
  type        = number
  default     = 8443

  validation {
    condition     = var.published_https_port > 1024 && var.published_https_port < 65536
    error_message = "published_https_port must be an unprivileged port (1025-65535) so no root is needed to bind it."
  }
}

variable "network_subnet" {
  description = "CIDR for the private Docker network. Deliberately unusual to dodge home/VPN/corporate range collisions."
  type        = string
  # 172.31.240.0/24 is inside RFC1918 but far from Docker's default 172.17/16
  # and the common 192.168.x / 10.x ranges most VPNs hand out.
  default = "172.31.240.0/24"
}

variable "elasticsearch_memory_mb" {
  description = "Hard memory ceiling for the Elasticsearch container (MB). Elasticsearch is the memory-hungry component."
  type        = number
  default     = 2048
}

variable "kibana_memory_mb" {
  description = "Hard memory ceiling for the Kibana container (MB)."
  type        = number
  default     = 1024
}

variable "nginx_memory_mb" {
  description = "Hard memory ceiling for the nginx edge (MB). The proxy is tiny."
  type        = number
  default     = 256
}

variable "elasticsearch_heap" {
  description = "JVM heap for Elasticsearch (-Xms=-Xmx). Rule of thumb: ~50% of elasticsearch_memory_mb, never above ~31g."
  type        = string
  default     = "1g"
}

variable "loopback_only_publish" {
  description = "If true, publish the HTTPS port on 127.0.0.1 only, so the stack is never reachable from the LAN. Set false to expose on all interfaces."
  type        = bool
  default     = true
}

variable "generated_inventory_path" {
  description = "Where Terraform writes the Ansible inventory built from state. This is the sole handover artefact between the two layers."
  type        = string
  # Relative to the terraform/ working dir -> lands in ansible/inventory/.
  default = "../ansible/inventory/hosts.yml"
}
