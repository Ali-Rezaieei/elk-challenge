# ---------------------------------------------------------------------------
# All tunables. Every value has a description; anything with a sensible default
# has one, so a reviewer can reproduce without editing files.
# ---------------------------------------------------------------------------

variable "hcloud_token" {
  description = "Hetzner Cloud API token (Read & Write). Supplied via TF_VAR_hcloud_token; never stored on disk."
  type        = string
  sensitive   = true
}

variable "project_prefix" {
  description = "Prefix applied to every Hetzner object so the stack is greppable and teardown can be scoped precisely."
  type        = string
  default     = "elk-cloud"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,30}$", var.project_prefix))
    error_message = "project_prefix must be 2-31 chars of [a-z0-9-] and start alphanumeric."
  }
}

variable "location" {
  description = "Hetzner location. nbg1/fsn1 are the German zones the task asks for."
  type        = string
  default     = "nbg1"
}

variable "server_type" {
  description = "Server type. Cheapest shared-vCPU with 8 GB RAM (ES + Kibana need it). cx32 = 4 vCPU / 8 GB (Intel)."
  type        = string
  default     = "cx32"
}

variable "server_image" {
  description = "Base OS image. Ubuntu 24.04 LTS."
  type        = string
  default     = "ubuntu-24.04"
}

variable "elastic_stack_version" {
  description = "Elasticsearch AND Kibana version (must match). Pinned for reproducibility."
  type        = string
  default     = "8.15.3"
}

variable "admin_user" {
  description = "Non-root admin/login user created by cloud-init. Ansible connects as this user and uses sudo."
  type        = string
  default     = "deploy"
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key uploaded to Hetzner and injected by cloud-init."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "allowed_ssh_cidrs" {
  description = "Source CIDRs allowed to reach port 22. Defaults to open so a reviewer can reproduce; lock down for real use."
  type        = list(string)
  default     = ["0.0.0.0/0", "::/0"]
}

variable "allowed_https_cidrs" {
  description = "Source CIDRs allowed to reach port 443 (the only application port)."
  type        = list(string)
  default     = ["0.0.0.0/0", "::/0"]
}

variable "network_ip_range" {
  description = "Private network range."
  type        = string
  default     = "10.90.0.0/16"
}

variable "subnet_ip_range" {
  description = "Private subnet range inside network_ip_range."
  type        = string
  default     = "10.90.1.0/24"
}

variable "generated_inventory_path" {
  description = "Where Terraform writes the Ansible inventory built from state (the only layer handover)."
  type        = string
  default     = "../ansible/inventory/hosts.yml"
}

variable "ssh_private_key_path" {
  description = "Private key matching ssh_public_key_path; written into the generated inventory so Ansible can connect."
  type        = string
  default     = "~/.ssh/id_ed25519"
}
