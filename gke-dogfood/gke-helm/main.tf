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
variable "gcp_credentials" {
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
variable "replicas" {
  default = "1"
}
variable "provisioner_daemons_per_replica" {
  default = "25"
}

provider "google" {
  project     = var.gcp_project_id
  credentials = var.gcp_credentials
  region      = "us-central1"
  zone        = "us-central1-a"
}

provider "google-beta" {
  project     = var.gcp_project_id
  credentials = var.gcp_credentials
  region      = "us-central1"
  zone        = "us-central1-a"
}

resource "google_service_account" "sa" {
  provider     = google-beta
  project      = var.gcp_project_id
  account_id   = "coder-${var.cluster_name}"
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
  provider   = google-beta
  name       = "coder-control-plane"
  location   = "us-central1-a"
  cluster    = google_container_cluster.coder.name
  node_count = 1

  node_config {
    preemptible  = false
    machine_type = var.node_size

    # Google recommends custom service accounts that have cloud-platform scope and permissions granted via IAM Roles.
    service_account = google_service_account.sa.email
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }
}

data "google_client_config" "current" {}

provider "helm" {
  alias = "gcp_cluster"
  kubernetes {
    host                   = google_container_cluster.coder.endpoint
    token                  = data.google_client_config.current.access_token
    client_key             = base64decode(google_container_cluster.coder.master_auth[0].client_key)
    client_certificate     = base64decode(google_container_cluster.coder.master_auth[0].client_certificate)
    cluster_ca_certificate = base64decode(google_container_cluster.coder.master_auth[0].cluster_ca_certificate)
  }
}
provider "kubernetes" {
  alias                  = "gcp_cluster"
  host                   = "https://${google_container_cluster.coder.endpoint}"
  token                  = data.google_client_config.current.access_token
  client_key             = base64decode(google_container_cluster.coder.master_auth[0].client_key)
  client_certificate     = base64decode(google_container_cluster.coder.master_auth[0].client_certificate)
  cluster_ca_certificate = base64decode(google_container_cluster.coder.master_auth[0].cluster_ca_certificate)
}
provider "kubectl" {
  alias                  = "gcp_cluster"
  host                   = "https://${google_container_cluster.coder.endpoint}"
  token                  = data.google_client_config.current.access_token
  client_key             = base64decode(google_container_cluster.coder.master_auth[0].client_key)
  client_certificate     = base64decode(google_container_cluster.coder.master_auth[0].client_certificate)
  cluster_ca_certificate = base64decode(google_container_cluster.coder.master_auth[0].cluster_ca_certificate)
  load_config_file       = false
}

resource "kubernetes_namespace" "cert-manager" {
  metadata {
    name = "cert-manager"
  }
  depends_on = [
    google_container_node_pool.coder_control_plane
  ]
}
resource "kubernetes_secret" "clouddns-serviceaccount" {
  provider = kubernetes.gcp_cluster
  metadata {
    name      = "clouddns-serviceaccount"
    namespace = "cert-manager"
  }
  data = {
    private_key = base64decode(google_service_account_key.key.private_key)
  }
  type       = "Opaque"
  depends_on = [kubernetes_namespace.cert-manager]
}
resource "helm_release" "cert-manager" {
  provider = helm.gcp_cluster
  depends_on = [
    kubernetes_namespace.cert-manager
  ]
  name       = "cert-manager"
  namespace  = "cert-manager"
  repository = "https://charts.jetstack.io"
  chart      = "cert-manager"
  set {
    name  = "installCRDs"
    value = "true"
  }
}
resource "helm_release" "postgres" {
  provider   = helm.gcp_cluster
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
    google_container_cluster.coder,
    google_container_node_pool.coder_control_plane
  ]
}

resource "time_sleep" "wait_for_certmanager" {
  depends_on = [
    helm_release.cert-manager
  ]
  create_duration = "10s"
}

resource "kubectl_manifest" "cluster_issuer" {
  provider = kubectl.gcp_cluster
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
  depends_on = [
    kubectl_manifest.cluster_issuer,
    helm_release.postgres
  ]
  create_duration = "30s"
}

resource "helm_release" "nginx-ingress" {
  provider   = helm.gcp_cluster
  name       = "nginx-ingress"
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  namespace  = "kube-system"
  depends_on = [
    google_container_node_pool.coder_control_plane
  ]
}

resource "helm_release" "coder" {
  provider = helm.gcp_cluster
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
    - name: CODER_PROMETHEUS_ENABLE
      value: "true"
    - name: CODER_PROMETHEUS_ADDRESS
      value: "127.0.0.1:2112" # default value, for visibility
    - name: CODER_PROVISIONER_DAEMONS
      value: "${var.provisioner_daemons_per_replica}"
    - name: CODER_EXPERIMENTAL
      value: "true"
    - name: CODER_TELEMETRY
      value: "false"
    - name: CODER_PG_CONNECTION_URL
      value: "postgres://coder:coder@coder-db-postgresql.default.svc.cluster.local:5432/coder?sslmode=disable"
  serviceAccount:
    workspacePerms: true
  resources:
    limits:
      cpu: 2
      memory: 4G
    requests:
      cpu: 0.5
      memory: 512M
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
  depends_on = [
    helm_release.coder
  ]
  create_duration = "60s"
}

# kubernetes_ingress_v1 does not seem to work
data "kubernetes_ingress_v1" "coder" {
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
  provider     = google-beta
  name         = "${var.cluster_name}.environments.bpmct.net."
  project      = var.gcp_project_id
  type         = "A"
  ttl          = 300
  managed_zone = var.dns_zone_name
  rrdatas      = [data.kubernetes_ingress_v1.coder.status.0.load_balancer.0.ingress.0.ip]
  depends_on = [
    data.kubernetes_ingress_v1.coder
  ]
}

output "coder_url" {
  value = "https://${var.cluster_name}.${var.root_domain}"
}

output "cluster_info" {
  value = {
    host                   = "https://${google_container_cluster.coder.endpoint}"
    token                  = data.google_client_config.current.access_token
    client_key             = base64decode(google_container_cluster.coder.master_auth[0].client_key)
    client_certificate     = base64decode(google_container_cluster.coder.master_auth[0].client_certificate)
    cluster_ca_certificate = base64decode(google_container_cluster.coder.master_auth[0].cluster_ca_certificate)
  }
  sensitive = true
}
