# ---------------------------------------------------------------------------
# Provider and version pinning. Pinned so the same code resolves the same way
# on the reviewer's machine as on mine.
# ---------------------------------------------------------------------------
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.48"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.4"
    }
  }
}

provider "hcloud" {
  # Token comes from the environment (TF_VAR_hcloud_token), which deploy.sh sets
  # from HCLOUD_TOKEN. It is never written to disk or committed.
  token = var.hcloud_token
}
