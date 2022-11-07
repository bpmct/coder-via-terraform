#!/bin/sh

NODE_SIZE=$1
FILE_NAME=workspace-$2

infracost breakdown --path ./gke-helm --format=json --terraform-var="node_size=$NODE_SIZE" --terraform-var="status=1" --out-file $FILE_NAME.workspace-json > /dev/null
COST=$(cat $FILE_NAME.workspace-json | jq -r '.totalHourlyCost' | xargs printf "$%.3f/hr")
jq -n --arg cost "$COST" '{"hourly_cost":$cost}'