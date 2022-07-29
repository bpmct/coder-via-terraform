#!/bin/sh

echo "Destroying all workspaces..."

# Delete all workspaces in a deployment
coder ls | awk 'NR>1 {print $1}' | xargs -n1 coder delete -y
