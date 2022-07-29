terraform {
  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.0"
    }
  }
}

provider "digitalocean" {
  # Authenticating with DIGITALOCEAN_TOKEN, DIGITALOCEAN_PROJECT_ID, 
  # and DIGITALOCEAN_SSH_KEY_ID environment variables
}

variable "CODER_DIGITALOCEAN_TOKEN" {
  type = string
}

variable "deployment_name" {
  type    = string
  default = "Coder"
}

variable "region" {
  type    = string
  default = "sfo"
}

resource "digitalocean_app" "coder" {
  spec {
    name   = "coder"
    region = var.region

    database {
      name       = "coder-db"
      engine     = "PG"
      production = false
    }

    service {
      name               = "coder"
      instance_count     = 1
      instance_size_slug = "professional-xs"

      image {
        registry_type = "DOCKER_HUB"
        registry      = "bencdr"
        repository    = "coder"
        tag           = "v0.8.1"
      }

      env {
        key   = "CODER_ADDRESS"
        value = "0.0.0.0:$${_self.PRIVATE_PORT}"
      }
      env {
        key   = "CODER_PG_CONNECTION_URL"
        value = "$${coder-db.DATABASE_URL}"
      }
      env {
        key   = "CODER_ACCESS_URL"
        value = "$${_self.PUBLIC_URL}"
      }
      env {
        key   = "DIGITALOCEAN_TOKEN"
        value = var.CODER_DIGITALOCEAN_TOKEN
      }

      # Ensure Coder is up and running before bootstrap.sh kicks off
      health_check {
        success_threshold = 10
      }
    }
  }

  provisioner "local-exec" {
    command = "CODER_URL=${self.default_ingress} ADD_TEMPLATE_DIGITALOCEAN=true ../bootstrap.sh"
  }

  provisioner "local-exec" {
    when    = "destroy"
    command = "CODER_CONFIG_DIR=$(cat coder_deployment.json | jq -r .config_dir) ../cleanup.sh"
  }

}

output "coder_deployment" {
  depends_on = [
    digitalocean_app.coder
  ]
  value = file("coder_deployment.json")
}





