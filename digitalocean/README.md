# Deploy Coder on DigitalOcean with Terraform

## Requirements (on the machine you're using to deploy)

- Terraform
- Coder CLI
- jq
- `DIGITALOCEAN_TOKEN` environment variable
  - [Generate a read/write token here](https://cloud.digitalocean.com/account/api/tokens/new)
- `TF_VAR_CODER_DIGITALOCEAN_TOKEN` environment variable
  - [Generate a read/write token here](https://cloud.digitalocean.com/account/api/tokens/new)
  - This is a token for the Coder server to authenticate with DigitalOcean to create instances
- `DIGITALOCEAN_PROJECT_ID` environment variable
  - Inspect the URL in the [DigitalOcean dashboard](https://cloud.digitalocean.com/projects)
  - Or use `doctl projects list` with the [DigitalOcean CLI](https://docs.digitalocean.com/reference/doctl/)
- `DIGITALOCEAN_SSH_KEY_ID` environment variable
  - Use `doctl compute ssh-key list` with the [DigitalOcean CLI](https://docs.digitalocean.com/reference/doctl/)
  - Or set to `0` to use no SSH key (this will send instances' root password to the admin via email)

## Steps

```sh
git clone https://github.com/bpmct/coder-via-terraform.git
cd coder-via-terraform/digitalocean
terraform apply
```
