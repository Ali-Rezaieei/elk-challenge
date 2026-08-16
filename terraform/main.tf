# ---------------------------------------------------------------------------
# INFRASTRUCTURE ONLY.
#
# This file provisions the "hardware": a private network, named volumes, and
# three containers with their resource limits, security options, port
# publishing and health checks. It configures NOTHING inside the services.
#
# The single handover to the configuration layer is a generated Ansible
# inventory (local_file, bottom of this file) built from Terraform state, so
# no address or container name is ever copied by hand.
#
# The container `entrypoint` is overridden with a tiny "wait for a sentinel
# file, then exec the real entrypoint" loop. That loop performs NO
# configuration; it only blocks the service from starting until Ansible has
# placed its config and TLS material. This is a deliberate handover contract
# between the layers, not configuration leaking into Terraform. See README:
# "Design decisions -> the sentinel handshake".
# ---------------------------------------------------------------------------

locals {
  name = {
    network         = "${var.project_prefix}-net"
    es              = "${var.project_prefix}-elasticsearch"
    kibana          = "${var.project_prefix}-kibana"
    nginx           = "${var.project_prefix}-nginx"
    vol_es_data     = "${var.project_prefix}-es-data"
    vol_es_config   = "${var.project_prefix}-es-config"
    vol_kb_config   = "${var.project_prefix}-kb-config"
    vol_nginx_conf  = "${var.project_prefix}-nginx-conf"
    vol_nginx_certs = "${var.project_prefix}-nginx-certs"
  }

  # In-container paths. Kept here so the inventory can hand them to Ansible and
  # there is a single source of truth for "where config lives".
  es_config_dir  = "/usr/share/elasticsearch/config"
  kb_config_dir  = "/usr/share/kibana/config"
  nginx_cert_dir = "/etc/nginx/certs"

  # Sentinel handshake: Ansible creates each file once it has finished placing
  # config + certs; the entrypoint override below blocks until it appears.
  es_sentinel    = "${local.es_config_dir}/.provisioned"
  kb_sentinel    = "${local.kb_config_dir}/.provisioned"
  nginx_sentinel = "${local.nginx_cert_dir}/.provisioned"

  # Entrypoint overrides. Each waits for its sentinel, then hands off to the
  # image's real entrypoint. `exec` replaces the shell so signals (SIGTERM on
  # `docker stop`) reach the service directly -> clean shutdown.
  es_entrypoint = ["/bin/bash", "-c",
    "echo '[bootstrap] waiting for Ansible to provision config...'; until [ -f ${local.es_sentinel} ]; do sleep 2; done; echo '[bootstrap] provisioned, starting Elasticsearch'; exec /usr/local/bin/docker-entrypoint.sh eswrapper"
  ]
  kb_entrypoint = ["/bin/bash", "-c",
    "echo '[bootstrap] waiting for Ansible to provision config...'; until [ -f ${local.kb_sentinel} ]; do sleep 2; done; echo '[bootstrap] provisioned, starting Kibana'; exec /usr/local/bin/kibana-docker"
  ]
  # nginx alpine ships busybox /bin/sh, not bash.
  nginx_entrypoint = ["/bin/sh", "-c",
    "echo '[bootstrap] waiting for Ansible to provision config...'; until [ -f ${local.nginx_sentinel} ]; do sleep 2; done; echo '[bootstrap] provisioned, starting nginx'; exec /docker-entrypoint.sh nginx -g 'daemon off;'"
  ]
}

# ---------------------------------------------------------------------------
# Images. Pulled and pinned by digest-able tag. keep_locally = true means a
# `terraform destroy` does not delete the pulled image, so the *next* cold
# start does not re-download gigabytes. (The acceptance-gate cold start removes
# volumes/containers/network, which is what actually makes a run "from zero".)
# ---------------------------------------------------------------------------
resource "docker_image" "elasticsearch" {
  name         = "docker.elastic.co/elasticsearch/elasticsearch:${var.elastic_stack_version}"
  keep_locally = true
}

resource "docker_image" "kibana" {
  name         = "docker.elastic.co/kibana/kibana:${var.elastic_stack_version}"
  keep_locally = true
}

resource "docker_image" "nginx" {
  name         = var.nginx_image
  keep_locally = true
}

# ---------------------------------------------------------------------------
# Private network. Elasticsearch and Kibana are reachable ONLY here; they have
# no published ports. The unusual subnet avoids colliding with the caller's
# home/VPN/corporate routes (preflight double-checks this at run time).
# ---------------------------------------------------------------------------
resource "docker_network" "internal" {
  name   = local.name.network
  driver = "bridge"

  ipam_config {
    subnet = var.network_subnet
  }
}

# ---------------------------------------------------------------------------
# Named volumes.
#  - es-data      : Elasticsearch indices (must persist across restarts).
#  - *-config     : seeded from each image on first mount, then Ansible overlays
#                   elasticsearch.yml / kibana.yml, the certs/ dir, and the
#                   keystore. Using a volume (not the read-only image layer)
#                   gives Ansible a writable place for the ES keystore.
#  - nginx-*      : proxy config and edge TLS material.
# ---------------------------------------------------------------------------
resource "docker_volume" "es_data" {
  name = local.name.vol_es_data
}

resource "docker_volume" "es_config" {
  name = local.name.vol_es_config
}

resource "docker_volume" "kb_config" {
  name = local.name.vol_kb_config
}

resource "docker_volume" "nginx_conf" {
  name = local.name.vol_nginx_conf
}

resource "docker_volume" "nginx_certs" {
  name = local.name.vol_nginx_certs
}

# ---------------------------------------------------------------------------
# Elasticsearch container.
# ---------------------------------------------------------------------------
resource "docker_container" "elasticsearch" {
  name     = local.name.es
  image    = docker_image.elasticsearch.image_id
  hostname = "elasticsearch"

  # Wait-for-sentinel handshake (see locals). No config work happens here.
  entrypoint = local.es_entrypoint

  # Heap is paired with the memory ceiling, so it lives with the other resource
  # limits (infrastructure), not in elasticsearch.yml. Everything security- or
  # cluster-related is set by Ansible in elasticsearch.yml.
  env = [
    "ES_JAVA_OPTS=-Xms${var.elasticsearch_heap} -Xmx${var.elasticsearch_heap}",
  ]

  memory = var.elasticsearch_memory_mb

  # File-descriptor ceiling Elasticsearch expects. We deliberately do NOT lock
  # memory (no memlock ulimit): that would require host tuning and privileged
  # capabilities, against the "runs anywhere" goal. Trade-off documented in
  # README (heap may be swapped under host pressure; acceptable for a local demo).
  ulimit {
    name = "nofile"
    soft = 65536
    hard = 65536
  }

  # --- Hardening ---------------------------------------------------------
  # The image already runs as the non-root `elasticsearch` user (uid 1000).
  security_opts = ["no-new-privileges:true"]
  capabilities {
    # Drop every Linux capability. Elasticsearch needs none when run as a
    # non-root user without memlock.
    drop = ["ALL"]
  }
  # NOTE: read_only root filesystem is NOT set for Elasticsearch: it writes to
  # logs/ and tmp on the image layer. Making it read-only would require several
  # tmpfs mounts and is brittle; documented as a known local-demo limitation.

  volumes {
    volume_name    = docker_volume.es_data.name
    container_path = "/usr/share/elasticsearch/data"
  }
  volumes {
    volume_name    = docker_volume.es_config.name
    container_path = local.es_config_dir
  }

  networks_advanced {
    name    = docker_network.internal.name
    aliases = ["elasticsearch"]
  }

  # Health = HTTPS port answers. 401 counts as healthy: it proves the TLS
  # listener is up AND security is enforcing auth. Uses curl, which ships in
  # the Elasticsearch image. Generous start_period covers first-boot + the
  # sentinel wait.
  healthcheck {
    # %%{ escapes Terraform's template directive marker so curl receives a
    # literal %{http_code}. $code is a shell var (no ${...} = no interpolation).
    test         = ["CMD-SHELL", "code=$(curl -s -k -o /dev/null -w '%%{http_code}' https://localhost:9200); [ \"$code\" = \"200\" ] || [ \"$code\" = \"401\" ]"]
    interval     = "10s"
    timeout      = "5s"
    retries      = 12
    start_period = "180s"
  }

  restart = "unless-stopped"
  # Don't let `terraform apply` return before the container object exists.
  must_run = true
}

# ---------------------------------------------------------------------------
# Kibana container.
# ---------------------------------------------------------------------------
resource "docker_container" "kibana" {
  name     = local.name.kibana
  image    = docker_image.kibana.image_id
  hostname = "kibana"

  entrypoint = local.kb_entrypoint

  memory = var.kibana_memory_mb

  security_opts = ["no-new-privileges:true"]
  capabilities {
    drop = ["ALL"]
  }

  volumes {
    volume_name    = docker_volume.kb_config.name
    container_path = local.kb_config_dir
  }

  networks_advanced {
    name    = docker_network.internal.name
    aliases = ["kibana"]
  }

  # Kibana reports 200 on /api/status only when fully "available"; 503 while
  # booting. Kibana serves TLS (server.ssl), hence https + -k.
  healthcheck {
    test         = ["CMD-SHELL", "code=$(curl -s -k -o /dev/null -w '%%{http_code}' https://localhost:5601/api/status); [ \"$code\" = \"200\" ]"]
    interval     = "10s"
    timeout      = "5s"
    retries      = 24
    start_period = "180s"
  }

  restart  = "unless-stopped"
  must_run = true

  # Kibana is useless before Elasticsearch exists; make the dependency explicit
  # so Terraform creates them in order (Ansible still gates on real readiness).
  depends_on = [docker_container.elasticsearch]
}

# ---------------------------------------------------------------------------
# nginx edge container - the ONLY thing with a published port.
# ---------------------------------------------------------------------------
resource "docker_container" "nginx" {
  name  = local.name.nginx
  image = docker_image.nginx.image_id

  entrypoint = local.nginx_entrypoint

  memory = var.nginx_memory_mb

  # --- Hardening ---------------------------------------------------------
  # nginx-unprivileged already runs as the non-root uid 101 and binds high
  # ports, so we can be strict here:
  security_opts = ["no-new-privileges:true"]
  capabilities {
    drop = ["ALL"]
  }
  read_only = true
  # A read-only root fs means nginx needs writable tmpfs for its runtime paths.
  tmpfs = {
    "/tmp"             = "rw,noexec,nosuid,size=16m"
    "/var/cache/nginx" = "rw,noexec,nosuid,size=32m"
    "/var/run"         = "rw,noexec,nosuid,size=8m"
  }

  # The single published port. Bound to 127.0.0.1 by default so the stack is
  # not reachable from the LAN - only from the host itself.
  ports {
    internal = 8443
    external = var.published_https_port
    ip       = var.loopback_only_publish ? "127.0.0.1" : "0.0.0.0"
  }

  volumes {
    volume_name    = docker_volume.nginx_conf.name
    container_path = "/etc/nginx/conf.d"
  }
  volumes {
    volume_name    = docker_volume.nginx_certs.name
    container_path = local.nginx_cert_dir
  }

  networks_advanced {
    name    = docker_network.internal.name
    aliases = ["nginx"]
  }

  # Health via a loopback-only plaintext stub server (see nginx default.conf).
  # busybox wget ships in the alpine image; curl does not.
  healthcheck {
    test         = ["CMD-SHELL", "wget -q -O /dev/null http://127.0.0.1:8081/healthz || exit 1"]
    interval     = "10s"
    timeout      = "5s"
    retries      = 6
    start_period = "60s"
  }

  restart  = "unless-stopped"
  must_run = true

  depends_on = [docker_container.kibana]
}

# ---------------------------------------------------------------------------
# THE HANDOVER ARTEFACT.
#
# Render the Ansible inventory from Terraform state. Because it is generated,
# the container names / network / port that Ansible targets can never drift
# from what Terraform actually created. This file is gitignored (it is state,
# not source) and is the ONLY coupling between the two layers.
# ---------------------------------------------------------------------------
resource "local_file" "ansible_inventory" {
  filename        = var.generated_inventory_path
  file_permission = "0644"

  content = <<-YAML
    ---
    # GENERATED BY TERRAFORM - DO NOT EDIT.
    # Source of truth: terraform state. Regenerate with `terraform apply`.
    all:
      vars:
        # Facts Ansible needs that only Terraform knows. Static configuration
        # lives in ansible/group_vars/all.yml instead.
        project_prefix: "${var.project_prefix}"
        docker_network_name: "${docker_network.internal.name}"
        network_subnet: "${var.network_subnet}"
        published_https_port: ${var.published_https_port}
        elastic_stack_version: "${var.elastic_stack_version}"
        es_config_dir: "${local.es_config_dir}"
        kb_config_dir: "${local.kb_config_dir}"
        nginx_cert_dir: "${local.nginx_cert_dir}"
        es_sentinel: "${local.es_sentinel}"
        kb_sentinel: "${local.kb_sentinel}"
        nginx_sentinel: "${local.nginx_sentinel}"
      children:
        elk:
          # All configuration happens over the Docker Engine API, so every host
          # uses the docker_api connection - no SSH daemon inside any container.
          vars:
            ansible_connection: community.docker.docker_api
          hosts:
            elasticsearch:
              ansible_host: "${docker_container.elasticsearch.name}"
            kibana:
              ansible_host: "${docker_container.kibana.name}"
            nginx:
              ansible_host: "${docker_container.nginx.name}"
  YAML
}
