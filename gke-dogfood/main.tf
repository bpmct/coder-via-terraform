terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = "0.5.3"
    }
  }
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

variable "cluster_type" {
  description = <<EOF
  virtual: vcluster + dedicated node pool | gke: complete cluster ($72/mo)
  EOF

  default = "virtual"

  validation {
    condition     = contains(["virtual", "gke"], var.cluster_type)
    error_message = "Must be one of following: virtual, gke."
  }

}

module "coder_cluster" {
  source = "./gke-helm"
  status = data.coder_workspace.me.start_count
  # status = 0

  gcp_project_id                  = "coder-dogfood"
  email                           = "me@bpmct.net"
  dns_zone_name                   = "environments"
  root_domain                     = "environments.bpmct.net"
  replicas                        = var.replicas
  provisioner_daemons_per_replica = var.provisioner_daemons_per_replica

  cluster_type    = var.cluster_type
  cluster_name    = "${data.coder_workspace.me.name}${data.coder_workspace.me.owner}"
  node_size       = var.node_size
  vcluster_parent = "master"
}

provider "kubernetes" {
  host                   = module.coder_cluster.cluster_info.host
  client_key             = module.coder_cluster.cluster_info.client_key
  client_certificate     = module.coder_cluster.cluster_info.client_certificate
  cluster_ca_certificate = module.coder_cluster.cluster_info.cluster_ca_certificate
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

    # -- Helm --
    mkdir ~/helm && cd ~/helm
    
    mkdir ~/helm/coder && cd ~/helm/coder
    helm repo add coder-v2 https://helm.coder.com/v2
    helm get values coder > values.yaml
    echo "helm upgrade coder v2/coder -f values.yaml" > update.sh

    mkdir ~/helm/postgres && cd ~/helm/postgres
    helm repo add bitnami https://charts.bitnami.com/bitnami
    helm get values coder-db > values.yaml
    echo "helm upgrade coder-db bitnami/postgresql -f values.yaml" > update.sh
    chmod +x update.sh
    echo "helm upgrade coder-db bitnami/postgresql -f values.yaml --set primary.extendedConfiguration='max_connections=1000' && helm get values coder-db > values.yaml" > increase-max-connections.sh
    chmod +x increase-max-connections.sh

    # -- Load tests --
    mkdir ~/load-tests && cd ~/load-tests
    git clone https://github.com/coder/loadscripts
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
    value = "https://console.cloud.google.com/kubernetes/clusters/details/us-central1-a/${data.coder_workspace.me.name}${data.coder_workspace.me.owner}"
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

output "kubeconfig" {
  value     = module.coder_cluster.kubeconfig
  sensitive = true
}
