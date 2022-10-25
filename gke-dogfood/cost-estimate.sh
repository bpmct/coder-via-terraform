#!/bin/sh

NODE_SIZE=$1
WORKSPACE=$2

infracost breakdown --path . --format=json --terraform-var="node_size=$NODE_SIZE" --out-file $WORKSPACE.json > /dev/null
COST=$(cat $WORKSPACE.json | jq -r '.totalHourlyCost' | xargs printf "$%.3f/hr")
jq -n --arg cost "$COST" '{"hourly_cost":$cost}'