provider "google-beta" {
  project = "coder-devrel"
  region  = "us-central1"
  zone    = "us-central1-a"
}

resource "google_service_account" "default" {
  provider     = google-beta
  account_id   = "coder-loadtest-sa"
  display_name = "Coder Service Account"
}

resource "google_container_cluster" "coder" {
  provider = google-beta
  name     = "coder-loadtest"
  location = "us-central1-a"

  # Delete initial node pool, we'll configure it seperately
  remove_default_node_pool = true
  initial_node_count       = 1

  # Better monitoring
  monitoring_config {
    managed_prometheus {
      enabled = true
    }
  }
}

resource "google_container_node_pool" "coder_control_plane" {
  provider   = google-beta
  name       = "coder-control-plane"
  location   = "us-central1-a"
  cluster    = google_container_cluster.coder.name
  node_count = 1

  node_config {
    preemptible  = false
    machine_type = "e2-medium" # 2 vCPUs, 4 GiB

    # Google recommends custom service accounts that have cloud-platform scope and permissions granted via IAM Roles.
    service_account = google_service_account.default.email
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }
}

data "google_client_config" "current" {}

provider "helm" {
  kubernetes {
    host               = google_container_cluster.coder.endpoint
    token              = data.google_client_config.current.access_token
    client_key         = base64decode(google_container_cluster.coder.master_auth[0].client_key)
    client_certificate = base64decode(google_container_cluster.coder.master_auth[0].client_certificate)

    cluster_ca_certificate = base64decode(google_container_cluster.coder.master_auth[0].cluster_ca_certificate)
  }
}

provider "kubernetes" {
  host               = "https://${google_container_cluster.coder.endpoint}"
  token              = data.google_client_config.current.access_token
  client_key         = base64decode(google_container_cluster.coder.master_auth[0].client_key)
  client_certificate = base64decode(google_container_cluster.coder.master_auth[0].client_certificate)

  cluster_ca_certificate = base64decode(google_container_cluster.coder.master_auth[0].cluster_ca_certificate)
}

resource "helm_release" "coder" {
  name  = "coder"
  chart = "https://github.com/coder/coder/releases/download/v0.10.2/coder_helm_0.10.2.tgz"

  values = [<<EOF
coder:
  replicaCount: 3
  image:
    tag: "v0.10.2"
  env:
    - name: CODER_TEMPLATE_AUTOIMPORT
      value: "kubernetes"
    - name: CODER_PROMETHEUS_ENABLE
      value: "true"
    - name: CODER_PROMETHEUS_ADDRESS
      value: "127.0.0.1:2112" # default value, for visibility
    - name: CODER_PROVISIONER_DAEMONS
      value: "5"
    - name: CODER_EXPERIMENTAL
      value: "true"
  serviceAccount:
    workspacePerms: true
  resources:
    limits:
      cpu: 2
      memory: 4G
    requests:
      cpu: 0.5
      memory: 512M
EOF
  ]
}

data "kubernetes_service" "coder" {
  metadata {
    name = "coder"
  }
  depends_on = [
    helm_release.coder
  ]
}

output "coder_ip" {
  value = data.kubernetes_service.coder.status.0.load_balancer.0.ingress.0.ip
}
