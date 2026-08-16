# ---------------------------------------------------------------------------
# Provider and Terraform version pinning.
#
# Why pin exactly: "reproducible" is only true if the same code resolves to the
# same providers on the reviewer's machine as on mine. A floating constraint
# would let a future provider release change plan output or break the schema.
# ---------------------------------------------------------------------------

terraform {
  # 1.5 introduced `check` blocks and is a safe, widely-available floor. We do
  # not need anything newer, so we keep the floor low to ease reproduction.
  required_version = ">= 1.5.0"

  required_providers {
    docker = {
      # kreuzwerker/docker is the de-facto Docker provider. We treat Docker as
      # the "infrastructure provider" for this local deployment (see README:
      # Design decisions -> why Docker).
      source  = "kreuzwerker/docker"
      version = "~> 3.0.2"
    }
  }
}

provider "docker" {
  # Talk to the local Docker Engine over the default socket. No remote host,
  # no TLS to the daemon: the whole point of the local target is zero external
  # dependencies. On Docker Desktop (macOS/Windows) this socket is proxied by
  # the VM transparently, so the same code works unchanged.
  host = var.docker_host
}
