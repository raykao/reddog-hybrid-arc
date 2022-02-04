#!/usr/bin/env bash
#set -eo pipefail
trap exit SIGINT SIGTERM

# Load supporting script files
source ./scripts/utils.sh
source ./scripts/load-vars-from-config.sh
source ./scripts/create-and-load-ssh-keys.sh

# Set azure CLI to allow extension installation without prompt
az config set extension.use_dynamic_install=yes_without_prompt

# Set variable to track azure login
AZURE_LOGIN=0
# Login to azure and check if connected via cloud shell
check_for_azure_login
check_for_cloud-shell

#####################################################################
# Start Functions
#####################################################################

# Initialize SQL in the branch cluster
sql_init() {
  # Preconfig SQL DB - Suggest moving this somehow to the Bootstrapper app itself
  run_on_jumpbox "DEBIAN_FRONTEND=noninteractive; curl https://packages.microsoft.com/keys/microsoft.asc | sudo apt-key add - ; curl https://packages.microsoft.com/config/ubuntu/18.04/prod.list | sudo tee /etc/apt/sources.list.d/msprod.list; sudo apt-get update; sudo ACCEPT_EULA=Y apt-get install -y mssql-tools unixodbc-dev;"

  SECONDS="90"
  # Wait 2 minutes for deps to deploy
  echo "[branch: $BRANCH_NAME] - Waiting $SECONDS seconds for Dependencies to deploy before installing base reddog-retail configs" | tee /dev/tty
  sleep $SECONDS 

  echo "[branch: $BRANCH_NAME] - Setup SQL User: $SQL_ADMIN_USER_NAME and DB" | tee /dev/tty

  echo "
  create database reddog;
  go
  use reddog;
  go
  create user $SQL_ADMIN_USER_NAME for login $SQL_ADMIN_USER_NAME;
  go
  create login $SQL_ADMIN_USER_NAME with password = '$SQL_ADMIN_PASSWD';
  go
  grant create table to $SQL_ADMIN_USER_NAME;
  grant control on schema::dbo to $SQL_ADMIN_USER_NAME;
  ALTER SERVER ROLE sysadmin ADD MEMBER $SQL_ADMIN_USER_NAME;
  go" | run_on_jumpbox "cat > temp.sql"
  
  run_on_jumpbox "
    kubectl wait --for=condition=ready pod -l app=mssql  -n sql; \
    /opt/mssql-tools/bin/sqlcmd -S 10.128.1.4 -U SA -P \"$SQL_ADMIN_PASSWD\" -i temp.sql"

  echo "[branch: $BRANCH_NAME] - Done SQL setup" | tee /dev/tty
}

#### Corp Transfer Function
rabbitmq_create_bindings(){
    # Manually create 2 queues/bindings in Rabbit MQ
        run_on_jumpbox \
        'kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=rabbitmq -n rabbitmq; \
        rabbitmqadmin -H 10.128.1.4 -u contosoadmin -p MyPassword123 list exchanges; \
        rabbitmqadmin -H 10.128.1.4 -u contosoadmin -p MyPassword123 list queues; \
        rabbitmqadmin -H 10.128.1.4 -u contosoadmin -p MyPassword123 declare queue name="corp-transfer-orders" durable=true auto_delete=true; \
        rabbitmqadmin -H 10.128.1.4 -u contosoadmin -p MyPassword123 declare binding source="orders" destination_type="queue" destination="corp-transfer-orders"; \
        rabbitmqadmin -H 10.128.1.4 -u contosoadmin -p MyPassword123 declare queue name="corp-transfer-ordercompleted" durable=true auto_delete=true; \
        rabbitmqadmin -H 10.128.1.4 -u contosoadmin -p MyPassword123 declare binding source="ordercompleted" destination_type="queue" destination="corp-transfer-ordercompleted";'
}

ssh_copy_key_to_jumpbox() {
  # Get the jump server public IP
  export JUMP_IP=$(cat ./outputs/$RG_NAME-bicep-outputs.json | jq -r .publicIP.value)

  # Copy the private key up to the jump server to be used to access the rest of the nodes
  echo "[branch: $BRANCH_NAME] - Copying private key to jump server ..." | tee /dev/tty
  echo "[branch: $BRANCH_NAME] - Waiting for cloud-init to finish configuring the jumpbox ..." | tee /dev/tty
  
  # try to copy the ssh key to the server. Check if the key is present in the jumpbox before that.
  if ! run_on_jumpbox -- file /home/reddogadmin/.ssh/id_rsa; then
    until scp -P 2022 -o "StrictHostKeyChecking no" -i $SSH_KEY_PATH/$SSH_KEY_NAME $SSH_KEY_PATH/$SSH_KEY_NAME $ADMIN_USER_NAME@$JUMP_IP:~/.ssh/id_rsa
    do
      sleep 5
    done
  fi 
}

# Loop through $BRANCHES (from config.json) and create branches
create_branches() {
  for branch in $BRANCHES
  do
    export BRANCH_NAME=$(echo $branch|jq -r '.branchName')
    export RG_LOCATION=$(echo $branch|jq -r '.location')
    export RG_NAME=$PREFIX-reddog-$BRANCH_NAME-$RG_LOCATION

    # Create log directory
    mkdir -p logs

    # Create Branch

    echo -e "\nWaiting for the $BRANCH_NAME branch creation to complete ..."
    echo "Check the log files in ./logs/$RG_NAME.log for its creation status"
    create_branch > ./logs/$RG_NAME.log 2>&1 &
  done

  # wait for all pids
  wait
}

# Create Branch
create_branch() {
  # Set the Subscriptoin
  az account set --subscription $SUBSCRIPTION_ID

  # Create the Resource Group to deploy the Webinar Environment
  az group create --name $RG_NAME --location $RG_LOCATION

  # Deploy the jump server and K3s cluster
  echo "[branch: $BRANCH_NAME] - Deploying branch office resources ..." | tee /dev/tty
  az deployment group create \
    --name $ARM_DEPLOYMENT_NAME \
    --mode Incremental \
    --resource-group $RG_NAME \
    --template-file ./scripts/branch-bicep/deploy.bicep \
    --parameters prefix=$PREFIX$BRANCH_NAME \
    --parameters k3sToken="$K3S_TOKEN" \
    --parameters adminUsername="$ADMIN_USER_NAME" \
    --parameters adminPublicKey="$SSH_PUB_KEY" \
    --parameters currentUserId="$CURRENT_USER_ID" \
    --parameters rabbitmqconnectionstring="amqp://contosoadmin:$RABBIT_MQ_PASSWD@rabbitmq.rabbitmq.svc.cluster.local:5672" \
    --parameters redispassword=$REDIS_PASSWD \
    --parameters sqldbconnectionstring="Server=tcp:mssql-deployment.sql.svc.cluster.local,1433;Initial Catalog=reddog;Persist Security Info=False;User ID=$SQL_ADMIN_USER_NAME;Password=$SQL_ADMIN_PASSWD;MultipleActiveResultSets=False;Encrypt=True;TrustServerCertificate=True;Connection Timeout=30;"

  # Save deployment outputs
  mkdir -p outputs
  az deployment group show -g $RG_NAME -n $ARM_DEPLOYMENT_NAME -o json --query properties.outputs | tee /dev/tty "./outputs/$RG_NAME-bicep-outputs.json"

  CLUSTER_IP_ADDRESS=$(cat ./outputs/$RG_NAME-bicep-outputs.json | jq -r .clusterIP.value)
  CLUSTER_FQDN=$(cat ./outputs/$RG_NAME-bicep-outputs.json | jq -r .clusterFQDN.value)

  # Get the host name for the control host
  JUMP_VM_NAME=$(cat ./outputs/$RG_NAME-bicep-outputs.json | jq -r .jumpVMName.value)
  echo "Jump Host Name: $JUMP_VM_NAME" 

  echo "[branch: $BRANCH_NAME] - Waiting for jump server to start" | tee /dev/tty
  while [[ "$(az vm list -d -g $RG_NAME -o tsv --query "[?name=='$JUMP_VM_NAME'].powerState")" != "VM running" ]]
  do
  echo "Waiting ..."
    sleep 5
  done
  echo "[branch: $BRANCH_NAME] - Jump Server Running!" | tee /dev/tty

  # Give the VM a few more seconds to become available
  sleep 20

  ssh_copy_key_to_jumpbox

  run_on_jumpbox "echo alias k=kubectl >> ~/.bashrc"
  echo "[branch: $BRANCH_NAME] - Jump Server connection info: ssh $ADMIN_USER_NAME@$JUMP_IP -i $SSH_KEY_PATH/$SSH_KEY_NAME -p 2022" | tee /dev/tty
  
  # Execute setup script on jump server
  # Get the host name for the control host
  CONTROL_HOST_NAME=$(cat ./outputs/$RG_NAME-bicep-outputs.json | jq -r .controlName.value)
  echo "Control Host Name: $CONTROL_HOST_NAME"
  echo "[branch: $BRANCH_NAME] - Executing setup script on jump server ..." | tee /dev/tty
  run_on_jumpbox "curl -sfL https://raw.githubusercontent.com/swgriffith/azure-guides/master/temp/get-kube-config.sh |CONTROL_HOST=$CONTROL_HOST_NAME sh -"
  # # Needed to temp fix the file permissions on the kubeconfig file - arc agent install checks the permissions and doesn't like previous 744
  # run_on_jumpbox "curl -sfL https://gist.githubusercontent.com/raykao/1b22f8a807eeda584137ac944c1ea2b9/raw/9d3bc2c52f268e202f708d0645b91f9fc768795e/get-kube-config.sh |CONTROL_HOST=$CONTROL_HOST_NAME sh -"

  # Deploy initial cluster resources
  echo "[branch: $BRANCH_NAME] - Creating Namespaces ..." | tee /dev/tty
  run_on_jumpbox "kubectl create ns reddog-retail;kubectl create ns rabbitmq;kubectl create ns redis;kubectl create ns dapr-system;kubectl create ns sql"

  # Create branch config secrets
  echo "[branch: $BRANCH_NAME] - Creating branch config secrets" | tee /dev/tty
  # Do not use Dapr
  # run_on_jumpbox "kubectl create secret generic -n reddog-retail branch.config --from-literal=store_id=$BRANCH_NAME --from-literal=makeline_base_url=http://$CLUSTER_IP_ADDRESS:8082 --from-literal=accounting_base_url=http://$CLUSTER_IP_ADDRESS:8083"
  # Use Dapr inside the UI pod
  run_on_jumpbox "kubectl create secret generic -n reddog-retail branch.config --from-literal=store_id=$BRANCH_NAME --from-literal=makeline_base_url=http://localhost:3500/v1.0/invoke/make-line-service/method --from-literal=accounting_base_url=http://localhost:3500/v1.0/invoke/accounting-service/method"

  echo "[branch: $BRANCH_NAME] - Creating RabbitMQ, Redis and MsSQL Password Secrets ..." | tee /dev/tty
  run_on_jumpbox "kubectl create secret generic rabbitmq-password --from-literal=rabbitmq-password=$RABBIT_MQ_PASSWD -n rabbitmq"
  run_on_jumpbox "kubectl create secret generic redis-password --from-literal=redis-password=$REDIS_PASSWD -n redis"
  run_on_jumpbox "kubectl create secret generic mssql --from-literal=SA_PASSWORD=$SQL_ADMIN_PASSWD -n sql "

  # Arc join the cluster
  # Get managed identity object id
  MI_BASENAME=$(cat ./outputs/$RG_NAME-bicep-outputs.json | jq -r .keyvaultName.value | sed 's/-kv.*//g')
  MI_SUFFIX="branchManagedIdentity"
  MI_APP_ID=$(cat ./outputs/$RG_NAME-bicep-outputs.json | jq -r .userAssignedMIAppID.value)
  #MI_OBJ_ID=$(az ad sp show --id $MI_APP_ID -o tsv --query objectId)
  MI_OBJ_ID=$(az  identity show -n ${MI_BASENAME}${MI_SUFFIX} -g $RG_NAME -o json| jq -r .principalId)
  echo "User Assigned Managed Identity App ID: $MI_APP_ID"
  echo "User Assigned Managed Identity Object ID: $MI_OBJ_ID"

  echo "[branch: $BRANCH_NAME] - Arc joining the branch cluster ..." | tee /dev/tty
  run_on_jumpbox "az connectedk8s connect -g $RG_NAME -n $RG_NAME-branch --distribution k3s --infrastructure generic --custom-locations-oid $MI_OBJ_ID"

  # Key Vault dependencies
  kv_init

  # copy pfx file to jump box and create secret there
  scp -P 2022 -i $SSH_KEY_PATH/$SSH_KEY_NAME $SSH_KEY_PATH/kv-$RG_NAME-cert.pfx $ADMIN_USER_NAME@$JUMP_IP:~/kv-$RG_NAME-cert.pfx
  
  # Get SP APP ID
  echo "Getting SP_APPID ..."
  SP_INFO=$(az ad sp list -o json --display-name "http://sp-$RG_NAME.microsoft.com")
  SP_APPID=$(echo $SP_INFO | jq -r .[].appId)
  echo "AKV SP_APPID: $SP_APPID"

  # Set k8s secret from jumpbox
  run_on_jumpbox "kubectl create secret generic -n reddog-retail reddog.secretstore --from-file=secretstore-cert=kv-$RG_NAME-cert.pfx --from-literal=vaultName=$KV_NAME --from-literal=spnClientId=$SP_APPID --from-literal=spnTenantId=$TENANT_ID"

  # Initial GitOps configuration
  #gitops_configuration_create
  gitops_dependency_create
  
  # Initialize SQL in the cluster
  sql_init

  # Initialize Dapr in the cluster
  echo "[branch: $BRANCH_NAME] - Deploing Dapr and the reddog app configs ..." | tee /dev/tty
  #dapr_init
  gitops_reddog_create

  echo "[branch: $BRANCH_NAME] - Enabling the App Service Arc Extension ..." | tee /dev/tty
  
  echo "[branch: $BRANCH_NAME] - Create Log Analytics Workspace" | tee /dev/tty
  # Setup Arc App Svc Extension
  APP_SVC_LA_WORKSPACE_NAME=$RG_NAME-la
  # Create Workspace
  az monitor log-analytics workspace create \
    --resource-group $RG_NAME \
    --workspace-name $APP_SVC_LA_WORKSPACE_NAME

  # Get Workspace ID and encode
  APP_SVC_LA_ID=$(az monitor log-analytics workspace show \
  --resource-group $RG_NAME \
  --workspace-name $APP_SVC_LA_WORKSPACE_NAME \
  --query customerId --output tsv)

  APP_SVC_LA_ID_ENCODED=$(printf %s $APP_SVC_LA_ID | base64) 

  APP_SVC_LA_KEY=$(az monitor log-analytics workspace get-shared-keys \
    --resource-group $RG_NAME \
    --workspace-name $APP_SVC_LA_WORKSPACE_NAME \
    --query primarySharedKey \
    --output tsv)

  APP_SVC_LA_KEY_ENCODED_SPACE=$(printf %s $APP_SVC_LA_KEY | base64)
  APP_SVC_LA_KEY_ENCODED=$(echo -n "${APP_SVC_LA_KEY_ENCODED_SPACE//[[:space:]]/}") 

  echo "[branch: $BRANCH_NAME] - Enable App Service Extension" | tee /dev/tty
  # Configure Extension. 
  run_on_jumpbox "
  az k8s-extension create
  --resource-group $RG_NAME
  --name $RG_NAME-appsvc
  --cluster-type connectedClusters
  --cluster-name $RG_NAME-branch
  --extension-type 'Microsoft.Web.Appservice'
  --release-train stable
  --auto-upgrade-minor-version true
  --scope cluster
  --release-namespace appservices
  --configuration-settings 'Microsoft.CustomLocation.ServiceAccount=default'
  --configuration-settings 'appsNamespace=appservices'
  --configuration-settings 'clusterName=$RG_NAME-branch'
  --configuration-settings 'loadBalancerIp=$CLUSTER_IP_ADDRESS'
  --configuration-settings 'buildService.storageClassName=local-path'
  --configuration-settings 'buildService.storageAccessMode=ReadWriteOnce'
  --configuration-settings 'customConfigMap=appservices/kube-environment-config'
  --configuration-settings 'logProcessor.appLogs.destination=log-analytics'
  --configuration-protected-settings 'logProcessor.appLogs.logAnalyticsConfig.customerId=${APP_SVC_LA_ID_ENCODED}'
  --configuration-protected-settings 'logProcessor.appLogs.logAnalyticsConfig.sharedKey=${APP_SVC_LA_KEY_ENCODED}'"

  EXTN_ID=$(az k8s-extension show \
  --cluster-type connectedClusters \
  --cluster-name $RG_NAME-branch \
  --resource-group $RG_NAME \
  --name $RG_NAME-appsvc \
  --query id \
  --output tsv)

  #TODO REMOVE
  echo Extension ID: $EXTN_ID
  
  echo "[branch: $BRANCH_NAME] - Wait for extension to be provisioned" | tee /dev/tty
  # The Azure Docs recommend waiting until the extension is fully created before proceeding with any additional steps. The below command can help with that.
  az resource wait --ids $EXTN_ID --custom "properties.installState!='Pending'" --api-version "2020-07-01-preview"

  CUSTOM_LOC_NAME=$RG_NAME-branch-cl
  ARC_CLUSTER_ID=$(az connectedk8s show --resource-group $RG_NAME --name $RG_NAME-branch --query id --output tsv)
  
  #TODO REMOVE
  echo Custom location name: $CUSTOM_LOC_NAME
  echo Arc Cluster ID: $ARC_CLUSTER_ID

  echo "[branch: $BRANCH_NAME] - Create Custom Location" | tee /dev/tty
  # Enable the feature on the connected cluster 
  run_on_jumpbox "az connectedk8s enable-features -n $RG_NAME-branch -g $RG_NAME --features cluster-connect custom-locations"

  az customlocation create \
    --resource-group $RG_NAME \
    --name $CUSTOM_LOC_NAME \
    --host-resource-id $ARC_CLUSTER_ID \
    --namespace appservices \
    --cluster-extension-ids $EXTN_ID

  CUSTOM_LOC_ID=$(az customlocation show \
    --resource-group $RG_NAME \
    --name $CUSTOM_LOC_NAME \
    --query id \
    --output tsv)

  read -r -d '' COMPLETE_MESSAGE << EOM
****************************************************
[branch: $BRANCH_NAME] - Deployment Complete! 
Jump server connection info: ssh $ADMIN_USER_NAME@$JUMP_IP -i $SSH_KEY_PATH/$SSH_KEY_NAME -p 2022
Cluster connection info: http://$CLUSTER_IP_ADDRESS:8081 or http://$CLUSTER_FQDN:8081
****************************************************
EOM
 
  echo "$COMPLETE_MESSAGE" | tee /dev/tty
}

# Corp Transfer
corp_transfer_fix_init() {
    # generates the corp-transfer-fx
    #func kubernetes deploy --name corp-transfer-service --javascript --registry ghcr.io/cloudnativegbb/paas-vnext --polling-interval 20 --cooldown-period 300 --dry-run > corp-transfer-fx.yaml
    export JUMP_IP=$(cat ./outputs/$RG_NAME-bicep-outputs.json | jq -r .publicIP.value)
    scp -P 2022 -i $SSH_KEY_PATH/$SSH_KEY_NAME $BASEDIR/manifests/corp-transfer-secret.yaml $ADMIN_USER_NAME@$JUMP_IP:~/corp-transfer-secret.yaml
    scp -P 2022 -i $SSH_KEY_PATH/$SSH_KEY_NAME $BASEDIR/manifests/corp-transfer-fx.yaml $ADMIN_USER_NAME@$JUMP_IP:~/corp-transfer-fx.yaml
}

corp_transfer_fix_apply() {
    # Corp Transfer Service Secret (need to run the func deploy and edit to only include secret)
    # we will copy these files to the jumpbox and execute the kubectl locally there
    echo \
    'kubectl apply -f corp-transfer-secret.yaml -n reddog-retail;
    kubectl apply -f corp-transfer-fx.yaml -n reddog-retail'
}

keda_init() {
    # KEDA
    echo \
    'helm repo add kedacore https://kedacore.github.io/charts;
    helm repo update;
    helm install keda kedacore/keda --version 2.0.0 --create-namespace --namespace keda'
}

#####################################################################
# End Functions
#####################################################################


# If logged in, execute hub resource deployments
if [[ ${AZURE_LOGIN} -eq 1 ]]; then

 # Get RG Prefix
  echo "Parameters"
  echo "------------------------------------------------"
  echo "ARM_DEPLOYMENT_NAME: $ARM_DEPLOYMENT_NAME"
  echo "RG_PREFIX: $PREFIX"
  echo "SUBSCRIPTION: $SUBSCRIPTION_ID"
  echo "TENANT_ID: $TENANT_ID"
  echo "K3S_TOKEN: $K3S_TOKEN"
  echo "ADMIN_USER_NAME: $ADMIN_USER_NAME"
  echo "SSH_KEY_PATH: $SSH_KEY_PATH"
  echo "SSH_KEY_NAME: $SSH_KEY_PATH/$SSH_KEY_NAME"
  echo "SSH_PUB_KEY: $SSH_PUB_KEY"
  echo "------------------------------------------------"

create_branches

fi