#!/usr/bin/env bash
set -eo pipefail

source ./scripts/load-vars-from-config.sh
source ./scripts/create-and-load-ssh-keys.sh cleanup

# Delete Branch Resource Groups
for branch in $BRANCHES
do
    export BRANCH_NAME=$(echo $branch|jq -r '.branchName')
    export RG_LOCATION=$(echo $branch|jq -r '.location')
    export RG_NAME=$PREFIX-reddog-$BRANCH_NAME-$RG_LOCATION

    # KV certificate cleanup
    echo "Deleting KV certificate"
    if [ -f $SSH_KEY_PATH/kv-$RG_NAME-cert.pfx ];
    then
        rm $SSH_KEY_PATH/kv-$RG_NAME-cert.pfx
    fi

    # Create Branch
    echo "Deleting Resource Group: $RG_NAME"
    az group delete -n $RG_NAME -y --no-wait
done