terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = "0.5.3"
    }
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 2.22.0"
    }
  }
}

provider "docker" {
  host = "unix:///var/run/dogfood-docker.sock"
}

provider "coder" {
}

data "coder_workspace" "me" {
}

variable "node_size" {
  default = "e2-highcpu-4"
}

variable "replicas" {
  default = "1"
}

variable "provisioner_daemons_per_replica" {
  default = "25"
}


module "coder_cluster" {
  source = "./gke-helm"
  status = data.coder_workspace.me.start_count


  gcp_credentials                 = "/home/coder/ben-credentials.json"
  gcp_project_id                  = "coder-devrel"
  email                           = "me@bpmct.net"
  dns_zone_name                   = "environments"
  root_domain                     = "environments.bpmct.net"
  node_size                       = var.node_size
  cluster_name                    = "${data.coder_workspace.me.name}${data.coder_workspace.me.owner}"
  replicas                        = var.replicas
  provisioner_daemons_per_replica = var.provisioner_daemons_per_replica
}

provider "kubernetes" {
  host                   = try(module.coder_cluster.cluster_info.host, "")
  token                  = try(module.coder_cluster.cluster_info.token, "")
  client_key             = try(module.coder_cluster.cluster_info.client_key, "")
  client_certificate     = try(module.coder_cluster.cluster_info.client_certificate, "")
  cluster_ca_certificate = try(module.coder_cluster.cluster_info.cluster_ca_certificate, "")
}

resource "coder_agent" "dev" {
  arch           = "amd64"
  os             = "linux"
  startup_script = <<EOF
    #!/bin/sh
    set -x
    # install and start code-server
    curl -fsSL https://code-server.dev/install.sh | sh
    code-server --auth none --port 13337 &
    sudo service docker start
    if [ -f ~/personalize ]; then ~/personalize 2>&1 | tee  ~/.personalize.log; fi
    EOF
}

resource "coder_app" "code-server" {
  agent_id  = coder_agent.dev.id
  name      = "code-server"
  url       = "http://localhost:13337/"
  icon      = "/icon/code.svg"
  subdomain = false
  share     = "owner"

  healthcheck {
    url       = "http://localhost:13337/healthz"
    interval  = 3
    threshold = 10
  }
}

resource "kubernetes_service_account" "dogfood" {
  count      = data.coder_workspace.me.start_count
  depends_on = [module.coder_cluster]

  metadata {
    name = "dogfood-workspace"
  }
}
resource "kubernetes_cluster_role_binding" "dogfood" {
  count      = data.coder_workspace.me.start_count
  depends_on = [module.coder_cluster]
  metadata {
    name = "dogfood-workspace"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }
  subject {
    kind = "ServiceAccount"
    name = kubernetes_service_account.dogfood[0].metadata[0].name
  }
}

resource "kubernetes_pod" "main" {
  count = data.coder_workspace.me.start_count
  depends_on = [
    kubernetes_persistent_volume_claim.home-directory,
    module.coder_cluster
  ]
  metadata {
    name = "dogfood-workspace"
  }
  spec {
    service_account_name = kubernetes_service_account.dogfood[0].metadata[0].name
    security_context {
      run_as_user = 1000
      fs_group    = 1000
    }
    container {
      name    = "dev"
      image   = "bencdr/devops:latest"
      command = ["sh", "-c", coder_agent.dev.init_script]
      security_context {
        run_as_user = "1000"
      }
      env {
        name  = "CODER_AGENT_TOKEN"
        value = coder_agent.dev.token
      }
      volume_mount {
        mount_path = "/home/coder"
        name       = "home-directory"
      }
    }
    volume {
      name = "home-directory"
      persistent_volume_claim {
        claim_name = kubernetes_persistent_volume_claim.home-directory.metadata.0.name
      }
    }
  }
}

data "external" "cost_estimate" {
  depends_on = [
    kubernetes_pod.main
  ]
  program = ["bash", "${path.module}/cost-estimate.sh", var.node_size, data.coder_workspace.me.id]
}

resource "coder_metadata" "info" {
  count       = data.coder_workspace.me.start_count
  resource_id = kubernetes_pod.main[0].id
  item {
    key   = "Deployment URL"
    value = module.coder_cluster.coder_url
  }
  item {
    key   = "Estimated hourly cost"
    value = data.external.cost_estimate.result.hourly_cost
  }
  item {
    key   = "GCP Console URL"
    value = "https://console.cloud.google.com/kubernetes/clusters/details/us-central1-a/${data.coder_workspace.me.name}"
  }
}

resource "kubernetes_persistent_volume_claim" "home-directory" {
  depends_on = [module.coder_cluster]

  metadata {
    name = "dogfood-workspace"
  }
  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = "10Gi"
      }
    }
  }
}

