# coder-via-terraform

My (extremely basic) Terraform to set up Coder deployments. This is not ready for production, but can be used as a reference, for load testing, demos, etc.

## Features

- Bootstrapped deployment with 1 user, 1 template, 1 workspace
- Attempts to delete all workspaces before destroyed

## Supported clouds

- [DigitalOcean App](./digitalocean/)

## TODO

- [ ] Providers
  - [ ] AWS
  - [ ] GCP
  - [ ] Dedicated machine with Docker
  - [ ] Kubernetes
- [ ] Release Coder on Docker Hub
- [ ] Create multiple users, templates, and workspaces
- [ ] Maybe: Support Terraform deployments as first-class feature in Coder's Terraform provider: [coder/coder#2291](https://github.com/coder/coder/issues/2291)
