terraform {
  required_providers {
    helm = {
      source = "hashicorp/helm"
    }
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "1.13.1"
    }
  }
}

variable "gcp_project_id" {
  sensitive = true
}
variable "node_size" {
  sensitive = true
}
variable "email" {
  sensitive = true
}
variable "dns_zone_name" {
  sensitive = true
}
variable "root_domain" {
}
variable "cluster_name" {
}
variable "cluster_type" {
  default = "virtual"
}
variable "vcluster_parent" {
}
variable "status" {
  default = 1
}
variable "replicas" {
  default = "1"
}
variable "provisioner_daemons_per_replica" {
  default = "25"
}
provider "google" {
  project = var.gcp_project_id
  region  = "us-central1"
  zone    = "us-central1-a"
}
provider "google-beta" {
  project = var.gcp_project_id
  region  = "us-central1"
  zone    = "us-central1-a"
}

resource "google_service_account" "sa" {
  provider     = google-beta
  project      = var.gcp_project_id
  account_id   = "coder-${var.cluster_name}-sa"
  display_name = "Coder ${var.cluster_name}"
}
resource "google_project_iam_custom_role" "dns" {
  provider = google-beta
  project  = var.gcp_project_id
  role_id  = "${var.cluster_name}DnsRole"
  title    = "${var.cluster_name} DNS Role"
  permissions = [
    "dns.changes.create",
    "dns.changes.get",
    "dns.managedZones.list",
    "dns.resourceRecordSets.create",
    "dns.resourceRecordSets.delete",
    "dns.resourceRecordSets.list",
    "dns.resourceRecordSets.update",
  ]
}
resource "google_project_iam_binding" "dns" {
  provider = google-beta
  project  = var.gcp_project_id
  role     = "projects/${var.gcp_project_id}/roles/${google_project_iam_custom_role.dns.role_id}"
  members = [
    "serviceAccount:${google_service_account.sa.email}",
  ]
}

resource "google_service_account_key" "key" {
  provider           = google-beta
  service_account_id = google_service_account.sa.name
}

resource "google_container_cluster" "coder" {

  # Create an actual cluster depending on cluster_type
  count = var.cluster_type == "gke" ? 1 : 0

  provider = google-beta
  name     = var.cluster_name
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
  count    = var.status
  provider = google-beta
  name     = local.nodepool_name
  location = "us-central1-a"
  cluster  = var.cluster_type == "virtual" ? var.vcluster_parent : google_container_cluster.coder[0].name

  autoscaling {
    min_node_count = 0
    max_node_count = 3
  }

  node_config {
    preemptible  = false
    machine_type = var.node_size

    dynamic "taint" {
      for_each = var.cluster_type == "virtual" ? [1] : []
      content {
        key    = "cluster-name"
        value  = var.cluster_name
        effect = "NO_EXECUTE"
      }
    }
    labels = {
      cluster-name = var.cluster_name
    }

    # Google recommends custom service accounts that have cloud-platform scope and permissions granted via IAM Roles.
    service_account = google_service_account.sa.email
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }
}

locals {
  # virtual: Use the kubeconfig from the host 
  kubeconfig_path = var.cluster_type == "virtual" ? "~/.kube/config" : null

  # gke: Use data from our newly created cluster
  host                   = var.cluster_type == "gke" ? "https://${google_container_cluster.coder[0].endpoint}" : null
  token                  = var.cluster_type == "gke" ? data.google_client_config.current.access_token : null
  client_key             = var.cluster_type == "gke" ? base64decode(google_container_cluster.coder[0].master_auth[0].client_key) : null
  client_certificate     = var.cluster_type == "gke" ? base64decode(google_container_cluster.coder[0].master_auth[0].client_certificate) : null
  cluster_ca_certificate = var.cluster_type == "gke" ? base64decode(google_container_cluster.coder[0].master_auth[0].cluster_ca_certificate) : null

  nodepool_name = var.cluster_type == "virtual" ? "vcluster-${var.cluster_name}" : "coder"
}

data "google_client_config" "current" {}

provider "helm" {
  alias = "main_cluster"
  kubernetes {
    config_path            = local.kubeconfig_path
    host                   = local.host
    token                  = local.token
    client_key             = local.client_key
    client_certificate     = local.client_certificate
    cluster_ca_certificate = local.cluster_ca_certificate
  }
}

provider "kubernetes" {
  config_path            = local.kubeconfig_path
  alias                  = "main_cluster"
  host                   = local.host
  token                  = local.token
  client_key             = local.client_key
  client_certificate     = local.client_certificate
  cluster_ca_certificate = local.cluster_ca_certificate
}

resource "kubernetes_namespace" "cluster_namespace" {
  provider = kubernetes.main_cluster
  count    = var.status
  metadata {
    name = var.cluster_type == "virtual" ? "vcluster-${var.cluster_name}" : "coder"
  }
  depends_on = [
    google_container_node_pool.coder_control_plane
  ]
}

resource "helm_release" "vcluster" {

  # Do not use a vcluster if we are making
  # a physical cluster
  count = var.cluster_type == "virtual" && var.status == 1 ? 1 : 0

  provider   = helm.main_cluster
  repository = "https://charts.loft.sh"
  name       = var.cluster_name
  namespace  = kubernetes_namespace.cluster_namespace[0].metadata[0].name
  chart      = "vcluster"
  wait       = true
  values = [<<EOF
vcluster:
  image: rancher/k3s:v1.23.5-k3s1   
service:
  type: LoadBalancer
sync:
  nodes:
    enabled: true
    nodeSelector: "cluster-name=${var.cluster_name}"
syncer:
  extraArgs:
  - --enforce-toleration=cluster-name=${var.cluster_name}:NoExecute
EOF
  ]
}

resource "time_sleep" "wait_for_vcluster" {

  # Do not use a vcluster if we are making
  # a physical cluster
  count = var.cluster_type == "virtual" && var.status == 1 ? 1 : 0

  create_duration = "60s"
  depends_on      = [helm_release.vcluster]
}

data "kubernetes_secret" "kubeconfig" {
  provider = kubernetes.main_cluster

  # Do not use a vcluster if we are making
  # a physical cluster
  count = var.cluster_type == "virtual" && var.status == 1 ? 1 : 0

  metadata {
    name      = "vc-${var.cluster_name}"
    namespace = kubernetes_namespace.cluster_namespace[0].metadata[0].name
  }
  depends_on = [time_sleep.wait_for_vcluster]
}

data "kubernetes_service" "cluster_host" {

  # Do not use a vcluster if we are making
  # a physical cluster
  count = var.cluster_type == "virtual" && var.status == 1 ? 1 : 0

  provider = kubernetes.main_cluster
  metadata {
    name      = var.cluster_name
    namespace = kubernetes_namespace.cluster_namespace[0].metadata[0].name
  }
  depends_on = [time_sleep.wait_for_vcluster]
}

locals {
  data_cluster_host                   = var.cluster_type == "gke" ? local.host : try("https://${data.kubernetes_service.cluster_host[0].status.0.load_balancer.0.ingress.0.ip}", "")
  data_cluster_client_key             = var.cluster_type == "gke" ? local.client_key : try(data.kubernetes_secret.kubeconfig[0].data.client-key, "")
  data_cluster_token                  = var.cluster_type == "gke" ? local.token : null
  data_cluster_client_certificate     = var.cluster_type == "gke" ? local.client_certificate : try(data.kubernetes_secret.kubeconfig[0].data.client-certificate, "")
  data_cluster_cluster_ca_certificate = var.cluster_type == "gke" ? local.cluster_ca_certificate : try(data.kubernetes_secret.kubeconfig[0].data.certificate-authority, "")
}

# Use the vcluster
provider "kubernetes" {
  alias                  = "data_cluster"
  host                   = local.data_cluster_host
  token                  = local.data_cluster_token
  client_certificate     = local.data_cluster_client_certificate
  client_key             = local.data_cluster_client_key
  cluster_ca_certificate = local.data_cluster_cluster_ca_certificate
}
provider "kubectl" {
  alias                  = "data_cluster"
  host                   = local.data_cluster_host
  token                  = local.data_cluster_token
  client_certificate     = local.data_cluster_client_certificate
  client_key             = local.data_cluster_client_key
  cluster_ca_certificate = local.data_cluster_cluster_ca_certificate
  load_config_file       = false
}
provider "helm" {
  alias = "data_cluster"
  kubernetes {
    host                   = local.data_cluster_host
    token                  = local.data_cluster_token
    client_certificate     = local.data_cluster_client_certificate
    client_key             = local.data_cluster_client_key
    cluster_ca_certificate = local.data_cluster_cluster_ca_certificate
  }
}

output "kubeconfig" {
  value     = var.cluster_type == "virtual" ? try(replace(data.kubernetes_secret.kubeconfig[0].data.config, "https://localhost:8443", "https://${data.kubernetes_service.cluster_host[0].status.0.load_balancer.0.ingress.0.ip}"), "") : "N/a"
  sensitive = true
}

output "cluster_info" {
  value = try({
    host                   = local.data_cluster_host
    client_certificate     = local.data_cluster_client_certificate
    client_key             = local.data_cluster_client_key
    cluster_ca_certificate = local.data_cluster_cluster_ca_certificate
  }, {})
  sensitive = true
}

resource "kubernetes_namespace" "cert-manager" {
  provider = kubernetes.data_cluster
  count    = var.status
  metadata {
    name = "${var.cluster_name}-cert-manager"
  }
  depends_on = [
    google_container_node_pool.coder_control_plane
  ]
}
resource "kubernetes_secret" "clouddns-serviceaccount" {
  count    = var.status
  provider = kubernetes.data_cluster
  metadata {
    name      = "clouddns-serviceaccount"
    namespace = "${var.cluster_name}-cert-manager"
  }
  data = {
    private_key = base64decode(google_service_account_key.key.private_key)
  }
  type       = "Opaque"
  depends_on = [kubernetes_namespace.cert-manager]
}
resource "helm_release" "cert-manager" {
  count    = var.status
  provider = helm.data_cluster
  depends_on = [
    kubernetes_namespace.cert-manager
  ]
  name       = "cert-manager"
  namespace  = "${var.cluster_name}-cert-manager"
  repository = "https://charts.jetstack.io"
  chart      = "cert-manager"
  set {
    name  = "installCRDs"
    value = "true"
  }
}
resource "helm_release" "postgres" {
  count      = var.status
  provider   = helm.data_cluster
  name       = "coder-db"
  repository = "https://charts.bitnami.com/bitnami"
  chart      = "postgresql"

  set {
    name  = "auth.username"
    value = "coder"
  }
  set {
    name  = "auth.password"
    value = "coder"
  }
  set {
    name  = "auth.database"
    value = "coder"
  }
  set {
    name  = "persistence.size"
    value = "10Gi"
  }
  depends_on = [
    google_container_node_pool.coder_control_plane
  ]
}

resource "time_sleep" "wait_for_certmanager" {
  count = var.status
  depends_on = [
    helm_release.cert-manager
  ]
  create_duration = "10s"
}

resource "kubectl_manifest" "cluster_issuer" {
  count    = var.status
  provider = kubectl.data_cluster
  depends_on = [
    time_sleep.wait_for_certmanager,
    kubernetes_secret.clouddns-serviceaccount
  ]
  yaml_body = <<YAML
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
  namespace: cert-manager
spec:
  acme:
    email: ${var.email}
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letesncrypt-prod-account-key
    solvers:
    - dns01:
        cloudDNS:
          project: ${var.gcp_project_id}
          serviceAccountSecretRef:
            name: clouddns-serviceaccount
            key: private_key
  YAML
}

resource "time_sleep" "wait_for_clusterissuer" {
  count = var.status
  depends_on = [
    kubectl_manifest.cluster_issuer,
    helm_release.postgres
  ]
  create_duration = "30s"
}

resource "helm_release" "nginx-ingress" {
  count      = var.status
  provider   = helm.data_cluster
  name       = "nginx-ingress"
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  namespace  = "kube-system"
  depends_on = [
    google_container_node_pool.coder_control_plane
  ]
}

resource "helm_release" "coder" {
  count    = var.status
  provider = helm.data_cluster
  name     = "coder"
  chart    = "https://github.com/coder/coder/releases/download/v0.10.2/coder_helm_0.10.2.tgz"

  # This will use the tunnel and an ephemeral DB
  values = [<<EOF
coder:
  replicaCount: ${var.replicas}
  env:
    - name: CODER_ACCESS_URL
      value: "https://${var.cluster_name}.${var.root_domain}"
    - name: CODER_WILDCARD_ACCESS_URL
      value: "*.${var.cluster_name}.${var.root_domain}"
    - name: CODER_PROMETHEUS_ENABLE
      value: "true"
    - name: CODER_TEMPLATE_AUTOIMPORT
      value: "kubernetes"
    - name: CODER_PROMETHEUS_ADDRESS
      value: "127.0.0.1:2112" # default value, for visibility
    - name: CODER_PROVISIONER_DAEMONS
      value: "${var.provisioner_daemons_per_replica}"
    - name: CODER_EXPERIMENTAL
      value: "true"
    - name: CODER_TELEMETRY
      value: "false"
    - name: CODER_TELEMETRY_ENABLE
      value: "false"
    - name: CODER_PG_CONNECTION_URL
      value: "postgres://coder:coder@coder-db-postgresql.default.svc.cluster.local:5432/coder?sslmode=disable"
  serviceAccount:
    workspacePerms: true
  ingress:
    enable: true
    className: "nginx"
    tls:
      enable: true
      secretName: coder-certs
    annotations:
      cert-manager.io/cluster-issuer: "letsencrypt-prod"
      cert-manager.io/issue-temporary-certificate: "true"
    host: "${var.cluster_name}.${var.root_domain}"
    wildcardHost: "*.${var.cluster_name}.${var.root_domain}"
EOF
  ]
  depends_on = [
    google_container_node_pool.coder_control_plane,
    helm_release.cert-manager,
    kubectl_manifest.cluster_issuer,
    helm_release.nginx-ingress,
    helm_release.postgres
  ]
}

resource "time_sleep" "wait_for_ip" {
  count = var.status
  depends_on = [
    helm_release.coder
  ]
  create_duration = "60s"
}

data "kubernetes_ingress_v1" "coder" {
  count    = var.status
  provider = kubernetes.data_cluster
  metadata {
    name      = "coder"
    namespace = "default"
  }
  depends_on = [
    helm_release.coder,
    time_sleep.wait_for_ip
  ]
}

resource "google_dns_record_set" "cluster_subdomain" {
  count        = var.status
  provider     = google-beta
  name         = "${var.cluster_name}.environments.bpmct.net."
  project      = var.gcp_project_id
  type         = "A"
  ttl          = 300
  managed_zone = var.dns_zone_name
  rrdatas      = [data.kubernetes_ingress_v1.coder[0].status.0.load_balancer.0.ingress.0.ip]
  depends_on = [
    data.kubernetes_ingress_v1.coder
  ]
}

output "coder_url" {
  value = "https://${var.cluster_name}.${var.root_domain}"
}
