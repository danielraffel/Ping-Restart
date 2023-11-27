#!/bin/bash

# Debug flag
DEBUG_MODE="off"

# Check if debug mode is on
debug_msg() {
  if [ "$DEBUG_MODE" = "on" ]; then
    echo "Debug: $1"
  fi
}

# Check prerequisites
check_prerequisites() {
  commands=("gcloud" "git" "curl" "expect" "ssh-keygen" "ssh-keyscan")
  urls=("https://cloud.google.com/sdk/docs/install" "https://github.com/git-guides/install-git" "https://curl.se/" "https://www.digitalocean.com/community/tutorials/expect-script-ssh-example-tutorial" "https://docs.github.com/en/authentication/connecting-to-github-with-ssh/generating-a-new-ssh-key-and-adding-it-to-the-ssh-agent" "https://man.openbsd.org/ssh-keyscan.1")

  missing_flag=0
  for i in ${!commands[@]}; do
    cmd=${commands[$i]}
    url=${urls[$i]}
    if ! command -v $cmd > /dev/null 2>&1; then
      echo "$cmd is not installed. Learn more: $url"
      missing_flag=1
    fi
  done

  if [ $missing_flag -eq 1 ]; then
    echo "Exiting script due to missing prerequisites."
    exit 1
  fi
}

# Function to select VM and set YOUR_STATIC_IP
select_vm_ip() {
  echo "Fetching Virtual Machine IPs..."
  vm_ips=$(gcloud compute instances list --project $YOUR_PROJECT_ID --format="value(networkInterfaces[0].accessConfigs[0].natIP)")
  
  if [ -z "$vm_ips" ]; then
    echo "No Virtual Machines with external IPs found in the selected project."
    exit 1
  fi

  echo "Select the Virtual Machine IP to monitor:"
  select ip in $vm_ips; do
    YOUR_STATIC_IP=$ip
    break
  done
}

# Function to prompt user and get inputs
confirm_and_prompt() {
  read -p $'This script will create Google Cloud functions that ping your server and auto restart it if there are issues.\nShall we proceed? (Y/N) ' answer
  case $answer in
    [Yy]* ) ;;
    * ) echo "Exiting script."; exit;;
  esac

  # Domain input
  while true; do
    read -p "Enter the domain to monitor (http://yourdomain.com): " domain
    if [[ $domain =~ ^http://.*$|^https://.*$ ]]; then
      YOURDOMAIN=$domain
      break
    else
      echo "Please enter the URL with http:// or https://"
    fi
  done

  # Confirm domain
  read -p "Monitor $YOURDOMAIN? (Y/N) " confirm_domain
  case $confirm_domain in
    [Yy]* ) ;;
    * ) confirm_and_prompt;;
  esac

  # Ask user to select a region for deploying cloud functions
  echo "Select the region closest to you for deploying cloud functions:"
  PS3="Enter your choice (1-3): "
  select region_option in "Oregon: us-west1" "Iowa: us-central1" "South Carolina: us-east1"; do
    case $region_option in
      "Oregon: us-west1") YOUR_REGION="us-west1"; break;;
      "Iowa: us-central1") YOUR_REGION="us-central1"; break;;
      "South Carolina: us-east1") YOUR_REGION="us-east1"; break;;
      *) echo "Invalid option. Please select a valid region.";;
    esac
  done

  # Google Project ID
  echo "Fetching Google Cloud project IDs..."
  project_ids=$(gcloud projects list --format="value(projectId)")
  if [ -z "$project_ids" ]; then
    echo "No Google Cloud projects found. Please create a project first."
    exit 1
  fi

  echo "Select the Google Cloud Project hosting your server:"
  select project in $project_ids; do
    YOUR_PROJECT_ID=$project
    break
  done

  # After selecting project, ask user to select VM IP
  select_vm_ip

  # Processing the domain to create a valid Cloud Function name
  PROCESSED_DOMAIN=$(echo $YOURDOMAIN | sed -e 's|http[s]\?://||g' | sed -e 's/www\.//' | sed -e 's/[.]/-/g' | tr '[:upper:]' '[:lower:]')

  # Generate function names based on processed domain
  FUNCTION_NAME_V2="restartvmservice-${PROCESSED_DOMAIN}"
  FUNCTION_NAME_V1="httpping-${PROCESSED_DOMAIN}"
  SCHEDULER_NAME="httppinger-${PROCESSED_DOMAIN}"
}

# Function to deploy a cloud function and check its deployment status
deploy_cloud_function() {
  local function_name=$1
  local entry_point=$2
  local runtime=$3
  local region=$YOUR_REGION
  local source_folder=$4
  local max_wait=240
  local wait_time=5
  local elapsed_time=0

  debug_msg "Deploying cloud function: $function_name with runtime $runtime from folder $source_folder"
  # Command to deploy the cloud function with the specified runtime and source folder
  gcloud functions deploy $function_name \
    --entry-point $entry_point \
    --runtime $runtime \
    --trigger-http \
    --allow-unauthenticated \
    --region $region \
    --source $source_folder

  while [ $elapsed_time -lt $max_wait ]; do
    if gcloud functions describe $function_name --region $region | grep -q "status: ACTIVE"; then
      debug_msg "$function_name deployed successfully."
      return 0
    fi
    sleep $wait_time
    elapsed_time=$((elapsed_time + wait_time))
  done

  echo "Deployment of $function_name timed out."
  return 1
}

# Function to update and deploy cloud functions
update_and_deploy_functions() {
  # Ensure the working directory is correct
  cd "$(dirname "$0")"

  # Use the previously processed domain
  debug_msg "Processed domain: $PROCESSED_DOMAIN"

  # Create a new directory to hold the function deployments
  DEPLOY_DIR="./$PROCESSED_DOMAIN"
  mkdir -p "$DEPLOY_DIR/v1_functions"
  mkdir -p "$DEPLOY_DIR/v2_functions"

  # Copy v2 function files and update them
  debug_msg "Copying and updating v2 function files..."
  cp v2_functions/index.js v2_functions/package.json "$DEPLOY_DIR/v2_functions/"
  sed -i '' "s/YOUR_PROJECT_ID/$YOUR_PROJECT_ID/g" "$DEPLOY_DIR/v2_functions/index.js"
  sed -i '' "s/YOUR_STATIC_IP/$YOUR_STATIC_IP/g" "$DEPLOY_DIR/v2_functions/index.js"

    # Deploy the v2 function
  deploy_cloud_function "$FUNCTION_NAME_V2" "restartVM" "nodejs18" "$YOUR_REGION" "$DEPLOY_DIR/v2_functions"
  # After deploying v2 function, retrieve URL
  YOUR_WEBHOOK_URL2=$(gcloud functions describe $FUNCTION_NAME_V2 --region $YOUR_REGION --format 'value(httpsTrigger.url)')
  debug_msg "$FUNCTION_NAME_V2 URL: $YOUR_WEBHOOK_URL2"

  # Use YOUR_WEBHOOK_URL2 in sed command for v1 function files
  sed -i '' "s/YOUR_WEBHOOK_URL2/$YOUR_WEBHOOK_URL2/g" "$DEPLOY_DIR/v1_functions/index.js"

  # Copy v1 function files and update them
  debug_msg "Copying and updating v1 function files..."
  cp v1_functions/index.js v1_functions/package.json "$DEPLOY_DIR/v1_functions/"
  sed -i '' "s/YOURDOMAIN.COM/$YOURDOMAIN/g" "$DEPLOY_DIR/v1_functions/index.js"
  sed -i '' "s/YOUR_WEBHOOK_URL2/$YOUR_WEBHOOK_URL2/g" "$DEPLOY_DIR/v1_functions/index.js"
  sed -i '' "s/YOUR_UNIQUE_PASSWORD/$YOUR_UNIQUE_PASSWORD/g" "$DEPLOY_DIR/v1_functions/index.js"

  # Deploy the v1 function
  deploy_cloud_function "$FUNCTION_NAME_V1" "httpPing" "nodejs20" "$YOUR_REGION" "$DEPLOY_DIR/v1_functions"

  # Retrieve and store the URL of the deployed v1 function
  if deploy_cloud_function "$FUNCTION_NAME_V1" "httpPing" "nodejs20" "$YOUR_REGION" "$DEPLOY_DIR/v1_functions"; then
    YOUR_WEBHOOK_URL1=$(gcloud functions describe $FUNCTION_NAME_V1 --region $YOUR_REGION --format 'value(httpsTrigger.url)')
    debug_msg "$FUNCTION_NAME_V1 URL: $YOUR_WEBHOOK_URL1"
  else
    echo "Failed to deploy $FUNCTION_NAME_V1. Exiting."
    exit 1
  fi

  # Creating Google Cloud Scheduler job named after the processed domain
  debug_msg "Creating Cloud Scheduler job named $SCHEDULER_NAME..."
  gcloud scheduler jobs create http $SCHEDULER_NAME --schedule="* * * * *" --uri=$YOUR_WEBHOOK_URL1 --message-body='{}' --region $YOUR_REGION

  # Setting roles for service account
  debug_msg "Setting roles for service account..."
  gcloud functions add-iam-policy-binding $FUNCTION_NAME_V2 \
      --region=$YOUR_REGION \
      --member="serviceAccount:$SERVICE_ACCOUNT@$YOUR_PROJECT_ID.iam.gserviceaccount.com" \
      --role='roles/cloudfunctions.invoker'

  gcloud projects add-iam-policy-binding $YOUR_PROJECT_ID \
      --member="serviceAccount:$SERVICE_ACCOUNT@$YOUR_PROJECT_ID.iam.gserviceaccount.com" \
      --role="roles/compute.instanceAdmin.v1"
}

# Generate a secure password for YOUR_UNIQUE_PASSWORD
generate_secure_password() {
  YOUR_UNIQUE_PASSWORD=$(openssl rand -base64 12)
  debug_msg "Generated secure password: $YOUR_UNIQUE_PASSWORD"
}

# Function to set debug mode
set_debug_mode() {
  if [ "$1" = "debug" ]; then
    DEBUG_MODE="on"
  fi
}

# Main script execution
main() {
  set_debug_mode $1
  check_prerequisites
  confirm_and_prompt
  generate_secure_password
  update_and_deploy_functions
}

# Run the script
main $@
