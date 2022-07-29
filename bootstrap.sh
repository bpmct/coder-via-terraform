#!/bin/bash

TMP_SESSION="${TMP_SESSION:-true}"

ADD_TEMPLATE_DIGITALOCEAN="${ADD_TEMPLATE_DIGITALOCEAN:-false}"

OUTPUT_FILE="${OUTPUT_FILE:-$(pwd)/coder_deployment.json}"

if [ "$TMP_SESSION" = true ]; then
    mkdir -p $(pwd)/.coder
    export CODER_CONFIG_DIR=$(pwd)/.coder
else
    export CODER_CONFIG_DIR="$HOME/.config/coderv2"
fi

RANDOM_PASSWORD=$(tr </dev/urandom -dc _A-Z-a-z-0-9 | head -c9)

export CODER_USERNAME="${CODER_USER:-admin}"
export CODER_EMAIL="${CODER_USER:-admin@coder.com}"
export CODER_PASSWORD="${CODER_PASSWORD:-$RANDOM_PASSWORD}"

# Log in to Coder
coder login $CODER_URL --email $CODER_EMAIL
export CODER_TOKEN=$(cat "$CODER_CONFIG_DIR/session")

# Clone the Coder repo to add templates
if [ ! -d $CODER_CONFIG_DIR/coder ]; then
    git clone https://github.com/coder/coder.git $CODER_CONFIG_DIR/coder
else
    cd $CODER_CONFIG_DIR/coder
    git pull https://github.com/coder/coder.git
fi

if [ "$ADD_TEMPLATE_DIGITALOCEAN" = true ]; then

    # Necessary parameters for DigitalOcean template
    cat <<EOF >$CODER_CONFIG_DIR/do_template.tfvars
step1_do_project_id: "$DIGITALOCEAN_PROJECT_ID"
step2_do_admin_ssh_key: "$DIGITALOCEAN_SSH_KEY_ID"
EOF

    # Necessary parameters for DigitalOcean template
    cat <<EOF >$CODER_CONFIG_DIR/do_workspace.tfvars
droplet_image: "ubuntu-22-04-x64"
droplet_size: "s-1vcpu-1gb"
home_volume_size: "20"
region: "sfo3"
step2_do_admin_ssh_key: "$DIGITALOCEAN_SSH_KEY_ID"
EOF

    # Add DigitalOcean template to Coder
    coder templates create -d $CODER_CONFIG_DIR/coder/examples/templates/do-linux -y --parameter-file $CODER_CONFIG_DIR/do_template.tfvars linux-droplet
    coder create --template="linux-droplet" --parameter-file $CODER_CONFIG_DIR/do_workspace.tfvars -y my-workspace --stop-after 2h

fi

jq -n "{ \"url\": \"$CODER_URL\", \"email\": \"$CODER_EMAIL\", \"password\": \"$CODER_PASSWORD\", \"token\": \"$CODER_TOKEN\", \"config_dir\": \"$CODER_CONFIG_DIR\" }" | tee $OUTPUT_FILE
