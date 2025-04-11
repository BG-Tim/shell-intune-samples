#!/bin/bash

# ------------------------------------------------------------------
# JAMF to Intune Migration Script OAuth2 Authentication Integration
# ------------------------------------------------------------------


JAMF_PRO_URL="https://yourenvironment.jamfcloud.com"  # URL of your Jamf Pro server
CLIENT_ID="your_client_id"                              # OAuth Client ID
CLIENT_SECRET="your_client_secret"                      # OAuth Client Secret
LOG="/Library/Logs/Microsoft/IntuneScripts/intuneMigration/intuneMigration.log"
JAMF_API_VERSION="new"     # Set to "classic" for (JSSResource) or new for (api)


# === Token Handling ===
access_token=""
token_expiration_epoch=0

# === Functions ===

# Obtain OAuth2 token
get_auth_token() {
  echo "Requesting OAuth2 token from Jamf..."
  response=$(curl --silent --location --request POST "${JAMF_PRO_URL}/api/oauth/token" \
    --header "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "grant_type=client_credentials" \
    --data-urlencode "client_id=${CLIENT_ID}" \
    --data-urlencode "client_secret=${CLIENT_SECRET}")

  access_token=$(echo "$response" | jq -r '.access_token')
  token_expires_in=$(echo "$response" | jq -r '.expires_in')

  if [[ -z "$access_token" || "$access_token" == "null" ]]; then
    echo "❌ ERROR: Failed to extract access token."
    exit 1
  fi

  current_epoch=$(date +%s)
  token_expiration_epoch=$((current_epoch + token_expires_in - 1))
  echo "✅ Access token retrieved."
}

# Refresh token if needed
check_token_expiration() {
  current_epoch=$(date +%s)
  if [[ "$token_expiration_epoch" -ge "$current_epoch" ]]; then
    echo "Token is still valid."
  else
    echo "Token expired. Refreshing..."
    get_auth_token
  fi
}

# Collect serial number of this Mac
get_serial_number() {
  system_profiler SPHardwareDataType | awk '/Serial Number/ {print $4}'
}

# Get Jamf Pro computer ID based on serial number
get_computer_id() {
  local serial_number="$1"
  local auth_token="$2"
  computer_id=$(curl -s -X GET \
    -H "Authorization: Bearer $auth_token" \
    "$JAMF_PRO_URL/api/v1/computers-inventory?filter=hardware.serialNumber==$serial_number" | jq -r '.results[0].id')
  echo "$computer_id"
}

# Exit if Jamf not managing device
check_if_managed() {
  if profiles -P | grep -q "com.jamfsoftware"; then
    echo "✅ Device is managed by Jamf."
  else
    echo "❌ Device is NOT managed by Jamf. Exiting."
    exit 0
  fi
}

# Start log redirection
startLog() {
  LOG_DIR=$(dirname "$LOG")
  [[ ! -d "$LOG_DIR" ]] && mkdir -p "$LOG_DIR"
  exec > >(tee -a "$LOG") 2>&1
}

# Install jq CLI parser if missing
check_and_install_jq() {
  if ! command -v jq &> /dev/null; then
    echo "Installing jq..."
    if command -v brew &> /dev/null; then brew install jq
    else
      ARCH=$(uname -m)
      JQ_URL="https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-macos-${ARCH}"
      curl -L "$JQ_URL" -o /tmp/jq && chmod +x /tmp/jq && sudo mv /tmp/jq /usr/local/bin/jq
    fi
  fi
}

# Install SwiftDialog utility
install_swiftDialog() {
  [ ! -f "/usr/local/bin/dialog" ] && \
  curl -L -o /tmp/dialog.pkg "https://github.com/swiftDialog/swiftDialog/releases/download/v2.5.2/dialog-2.5.2-4777.pkg" && \
  sudo installer -pkg /tmp/dialog.pkg -target / && rm /tmp/dialog.pkg
}

# Install Microsoft Company Portal if not present
install_cp() {
  [ ! -d "/Applications/Company Portal.app" ] && \
  curl -L -o /tmp/cp.pkg "https://go.microsoft.com/fwlink?linkid=853070" && \
  sudo installer -pkg /tmp/cp.pkg -target / && rm /tmp/cp.pkg
}

# Prompt user to begin migration
prompt_migration() {
  /usr/local/bin/dialog \
    --bannertitle "Prepare for Device Migration" \
    --message "Your device is scheduled to be migrated from **Jamf** to **Microsoft Intune**.\n\nThis process will take approximately **20 minutes**, during which you will **not be able to use your Mac**." \
    --button1text "Migrate" \
    --button2text "Exit" \
    --blurscreen \
    --bannerimage colour=blue \
    --titlefont shadow=1 \
    --width 750 \
    --height 450 \
    --icon /Applications/Company\ Portal.app/Contents/Resources/AppIcon.icns

  # Check which button was clicked based on the exit code
  if [[ "$?" -eq 0 ]]; then
    echo "User is ready to start the migration."
    return 0  # Proceed with migration
  else
    echo "User chose not to migrate at this time."
    exit 1  # Exit the script
  fi
}

# Show migration in-progress dialog
start_progress_dialog() {
  COMMAND_FILE="/tmp/dialog_command"
  echo "Initializing migration..." > "$COMMAND_FILE"
  /usr/local/bin/dialog \
    --bannertitle "Device Migration in Progress" \
    --icon /Applications/Company\ Portal.app/Contents/Resources/AppIcon.icns \
    --bannerimage colour=blue \
    --titlefont shadow=1 \
    --message "Your device is being migrated from Jamf to Microsoft Intune. Please do not power off or disconnect your device during this process." \
    --blurscreen \
    --force \
    --no-buttons \
    --progress \
    --width 750 \
    --height 450 \
    --commandfile "$COMMAND_FILE" &
  
  DIALOG_PID=$!
}

# Update progress dialog
update_progress() {
  echo "progress: $1" > "$COMMAND_FILE"
  echo "progresstext: $2" >> "$COMMAND_FILE"
  sleep 1
}

# Remove Jamf from system
remove_jamf_framework() {
  update_progress 50 "Removing Jamf framework..."
  if command -v jamf >/dev/null; then
    sudo jamf removeFramework && echo "Jamf removed." || echo "Removal failed."
  fi
}

# Check ADE enrollment status
check_ade_enrollment() {
  ade_status=$(profiles status -type enrollment 2>/dev/null | grep -i "Enrolled via DEP: Yes")
  [[ -n "$ade_status" ]] && ADE_ENROLLED=true || ADE_ENROLLED=false
}

# Re-enroll device if ADE
renew_profiles() {
  sudo profiles renew -type enrollment
  echo "Profiles renewed."
}

# Launch Company Portal
launch_company_portal() {
  open -a "/Applications/Company Portal.app"
  osascript -e 'tell application "Company Portal" to activate'
}

# Show sign-in prompt
cp_sign_in_message() {
  /usr/local/bin/dialog \
    --bannertitle "Action Required: Sign in to Company Portal" \
    --message "To complete your device setup, you must sign in to the Company Portal app using your **Entra (Microsoft)** credentials.\n\nFailure to sign in to Company Portal will result in the loss of access to corporate resources such as **e-Mail** and **other essential services**.\n\nWhen you close this dialog, Company Portal will be open your screen, click **Sign-in** and complete the process to avoid service disruptions." \
    --button1text "Got it" \
    --blurscreen \
    --bannerimage colour=blue \
    --titlefont shadow=1 \
    --width 750 \
    --height 450 \
    --icon /Applications/Company\ Portal.app/Contents/Resources/AppIcon.icns
}

# Show ADE enrollment prompt
ade_enrollment_message() {
  /usr/local/bin/dialog \
    --bannertitle "Action Required: Complete Device Enrollment" \
    --message "Your device is **ADE-enrolled** and requires additional setup to complete enrollment into **Intune**.\n\nPlease follow the setup assistant screens to sign in with your **Entra (Microsoft)** credentials. This process is necessary to gain access to corporate resources, including **e-Mail** and other essential services.\n\nWhen you close this dialog, the setup assistant will open. Follow the prompts to complete the enrollment process." \
    --button1text "Got it" \
    --blurscreen \
    --bannerimage colour=blue \
    --titlefont shadow=1 \
    --width 750 \
    --height 450 \
    --icon /Applications/Company\ Portal.app/Contents/Resources/AppIcon.icns
}

# Function to display "Waiting for Intune" message with spinner
waiting_for_intune() {
  /usr/local/bin/dialog \
    --bannertitle "Status: Waiting for Intune" \
    --message "Your device setup is in progress.\n\nWe're currently waiting for Intune to complete the necessary setup. This may take a few minutes.\n\nPlease keep this window open until setup is complete." \
    --blurscreen \
    --bannerimage colour=blue \
    --titlefont shadow=1 \
    --progress \
    --width 750 \
    --height 450 \
    --icon /Applications/Company\ Portal.app/Contents/Resources/AppIcon.icns \
    --no-buttons \
    --progress &
  
  # Capture the dialog process ID to close it later if needed
  DIALOG_PID=$!
}

# Wait for MDM profile to be removed
wait_for_management_profile_removal() {
  local timeout=1800 interval=5 elapsed=0
  while true; do
    local output=$(profiles show type -enrollment 2>/dev/null)
    if echo "$output" | grep -q "There are no configuration profiles installed" || \
       ! echo "$output" | grep -q "com.apple.mdm"; then
      echo "MDM profile removed."
      break
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
    [[ $elapsed -ge $timeout ]] && echo "Timeout waiting for profile removal." && exit 1
  done
}

# Unmanage via new Jamf API
unmanage_device_jamf_new() {
  local computer_id="$1" auth_token="$2"
  response=$(curl -s -X POST \
    -H "Authorization: Bearer $auth_token" \
    "$JAMF_PRO_URL/api/v1/computer-inventory/$computer_id/remove-mdm-profile")

  if echo "$response" | jq -e '.commandUuid' >/dev/null; then
    echo "Unmanage command sent."
    remove_jamf_framework
  else
    echo "Unmanage failed: $response"
    exit 1
  fi
}

# Unmanage via classic API
unmanage_device_jamf_classic() {
  local computer_id="$1" auth_token="$2"
  response=$(curl -s -X POST \
    -H "Authorization: Bearer $auth_token" \
    "$JAMF_PRO_URL/JSSResource/computercommands/command/UnmanageDevice/id/$computer_id")

  command_uuid=$(echo "$response" | xmllint --xpath 'string(//command_uuid)' - 2>/dev/null)
  if [[ -n "$command_uuid" ]]; then
    echo "Unmanage command sent."
    remove_jamf_framework
  else
    echo "Unmanage failed: $response"
    exit 1
  fi
}

# === Main Execution ===
startLog
check_if_managed
check_ade_enrollment
install_cp
install_swiftDialog
check_and_install_jq
prompt_migration
start_progress_dialog

check_token_expiration
serial_number=$(get_serial_number)
echo "Serial Number: $serial_number"
computer_id=$(get_computer_id "$serial_number" "$access_token")
echo "Computer ID: $computer_id"

if [[ -n "$computer_id" ]]; then
  case $JAMF_API_VERSION in
    classic) unmanage_device_jamf_classic "$computer_id" "$access_token" ;;
    new)     unmanage_device_jamf_new "$computer_id" "$access_token" ;;
    *)       echo "Invalid JAMF_API_VERSION" && exit 1 ;;
  esac
else
  echo "Computer ID not found."
  exit 1
fi

wait_for_management_profile_removal

if [[ "$ADE_ENROLLED" == true ]]; then
  ade_enrollment_message
  renew_profiles
  sleep 5
  waiting_for_intune 
else
  cp_sign_in_message
  launch_company_portal
fi

exit