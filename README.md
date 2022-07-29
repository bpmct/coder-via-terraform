# coder-via-terraform

Set up Coder with Terraform.

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
- [ ] Create multiple users, templates, and workspaces
- [ ] Maybe: Support Terraform deployments as first-class feature in Coder's Terraform provider: [coder/coder#2291](https://github.com/coder/coder/issues/2291)
