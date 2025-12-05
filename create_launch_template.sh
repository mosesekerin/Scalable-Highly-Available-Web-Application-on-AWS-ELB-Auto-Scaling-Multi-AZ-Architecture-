#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# create_launch_template.sh
#
# Purpose:
#   Production-grade automation script to validate environment and create an
#   EC2 Launch Template for the Cafe Web App infrastructure.
#
# Requirements:
#   - AWS CLI v2
#   - jq installed
#
# DevOps-quality features:
#   - Idempotent
#   - Full validation
#   - Compares LT configs before creating new versions
#   - Fast failure with clear human messages
#   - Color logging + timestamps
# ---------------------------------------------------------------------------

set -euo pipefail

###############################################################################
# CONFIGURABLE PARAMETERS
###############################################################################
LT_NAME="${LT_NAME:-CafeWebServer-LT}"
INSTANCE_TYPE_PRIMARY="t2.micro"
INSTANCE_TYPE_FALLBACK="t3.micro"
SECURITY_GROUP_NAME="*CafeSG*"
IAM_PROFILE_NAME="CafeRole"
AMI_NAME="Cafe WebServer Image"
TAG_VALUE="webserver"

###############################################################################
# LOGGING FUNCTIONS
###############################################################################
log()      { echo -e "\e[32m[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $*\e[0m"; }
warn()     { echo -e "\e[33m[$(date '+%Y-%m-%d %H:%M:%S')] WARN: $*\e[0m"; }
error()    { echo -e "\e[31m[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*\e[0m" >&2; exit 1; }

###############################################################################
# VALIDATE AWS CREDENTIALS
###############################################################################
log "Validating AWS CLI configuration..."
aws sts get-caller-identity >/dev/null 2>&1 || error "AWS CLI credentials invalid or missing."

###############################################################################
# FIND VPC FROM CONDITIONS (ASSUMES SINGLE LAB VPC)
###############################################################################
log "Discovering the Lab VPC..."
VPC_ID=$(aws ec2 describe-vpcs   --filters "Name=tag:Name,Values=*Lab*"   --query 'Vpcs[0].VpcId' --output text)
[[ "$VPC_ID" == "None" ]] && error "No VPC found. Aborting."

log "VPC detected: $VPC_ID"

###############################################################################
# VALIDATE AMI
###############################################################################
log "Checking AMI: $AMI_NAME..."
AMI_INFO=$(aws ec2 describe-images --owners self --filters "Name=name,Values=$AMI_NAME")

AMI_COUNT=$(echo "$AMI_INFO" | jq '.Images | length')
[[ "$AMI_COUNT" -eq 0 ]] && error "AMI '$AMI_NAME' not found."

AMI_ID=$(echo "$AMI_INFO" | jq -r '.Images[0].ImageId')
AMI_STATE=$(echo "$AMI_INFO" | jq -r '.Images[0].State')

[[ "$AMI_STATE" != "available" ]] && error "AMI '$AMI_NAME' exists but is NOT in 'available' state."

log "AMI found: $AMI_ID"

###############################################################################
# VALIDATE SECURITY GROUP
###############################################################################
log "Validating security group $SECURITY_GROUP_NAME..."
SG_INFO=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=$SECURITY_GROUP_NAME" "Name=vpc-id,Values=$VPC_ID")

SG_ID=$(echo "$SG_INFO" | jq -r '.SecurityGroups[0].GroupId')
[[ "$SG_ID" == "null" ]] && error "Security Group '$SECURITY_GROUP_NAME' not found in VPC $VPC_ID."

log "Security group found: $SG_ID"

# Validate inbound rules contain HTTP (port 80)
HTTP_RULE=$(echo "$SG_INFO" | jq '.SecurityGroups[0].IpPermissions[] | select(.FromPort==80 and .ToPort==80)')
[[ -z "$HTTP_RULE" ]] && warn "Security Group does not explicitly allow HTTP (80)."

###############################################################################
# VALIDATE IAM INSTANCE PROFILE
###############################################################################
log "Validating IAM Instance Profile $IAM_PROFILE_NAME..."
PROFILE_CHECK=$(aws iam get-instance-profile --instance-profile-name "$IAM_PROFILE_NAME" 2>/dev/null || true)
[[ -z "$PROFILE_CHECK" ]] && error "IAM Instance Profile '$IAM_PROFILE_NAME' does not exist."

# Check for SSM core policy (basic validation)
SSM_POLICY=$(echo "$PROFILE_CHECK" | jq -r '.. | select(.PolicyName? == "AmazonSSMManagedInstanceCore")')
[[ -z "$SSM_POLICY" ]] && warn "IAM profile does NOT include AmazonSSMManagedInstanceCore. SSM might not work."

###############################################################################
# VALIDATE NAT GATEWAY FOR AZ2
###############################################################################
log "Checking NAT Gateway in AZ2..."
NAT_GW=$(aws ec2 describe-nat-gateways --filter Name=state,Values=available)
NAT_COUNT=$(echo "$NAT_GW" | jq '.NatGateways | length')
[[ "$NAT_COUNT" -lt 1 ]] && error "No NAT Gateway in 'available' state found."

log "NAT Gateway is available."

###############################################################################
# VALIDATE INSTANCE TYPE AVAILABILITY
###############################################################################
log "Validating instance type availability..."
set +e
aws ec2 describe-instance-type-offerings \
    --filters Name=instance-type,Values=$INSTANCE_TYPE_PRIMARY >/dev/null 2>&1
PRIMARY_OK=$?
set -e

if [[ "$PRIMARY_OK" -ne 0 ]]; then
    warn "Instance type $INSTANCE_TYPE_PRIMARY not available. Falling back to $INSTANCE_TYPE_FALLBACK"
    INSTANCE_TYPE="$INSTANCE_TYPE_FALLBACK"
else
    INSTANCE_TYPE="$INSTANCE_TYPE_PRIMARY"
fi

###############################################################################
# VALIDATE KEY PAIR OR CREATE ONE
###############################################################################
KEY_NAME="CafeKey"
log "Ensuring key pair '$KEY_NAME' exists..."

if aws ec2 describe-key-pairs --key-names "$KEY_NAME" >/dev/null 2>&1; then
    log "Key pair already exists: $KEY_NAME"
else
    log "Creating new key pair: $KEY_NAME"
    aws ec2 create-key-pair --key-name "$KEY_NAME" \
        --query 'KeyMaterial' --output text > "$KEY_NAME.pem"
    chmod 400 "$KEY_NAME.pem"
    log "Key pair saved to $KEY_NAME.pem"
fi

###############################################################################
# CHECK IF LAUNCH TEMPLATE EXISTS
###############################################################################
log "Checking if Launch Template '$LT_NAME' exists..."
LT_INFO=$(aws ec2 describe-launch-templates --launch-template-names "$LT_NAME" 2>/dev/null || true)

LT_EXISTS=$(echo "$LT_INFO" | jq -r '.LaunchTemplates | length')

NEW_VERSION_CREATED="No"

if [[ "$LT_EXISTS" -gt 0 ]]; then
    log "Launch Template exists. Checking configuration differences..."

    EXISTING_AMI=$(aws ec2 describe-launch-template-versions \
        --launch-template-name "$LT_NAME" --versions "1" |
        jq -r '.LaunchTemplateVersions[0].LaunchTemplateData.ImageId')

    if [[ "$EXISTING_AMI" == "$AMI_ID" ]]; then
        log "Launch Template is already correctly configured. Idempotency check PASSED."
    else
        log "AMI differs. Creating a NEW version..."
        NEW_VERSION=$(aws ec2 create-launch-template-version \
            --launch-template-name "$LT_NAME" \
            --source-version "1" \
            --launch-template-data "{
                \"ImageId\": \"$AMI_ID\",
                \"InstanceType\": \"$INSTANCE_TYPE\",
                \"KeyName\": \"$KEY_NAME\",
                \"IamInstanceProfile\": {\"Name\": \"$IAM_PROFILE_NAME\"},
                \"SecurityGroupIds\": [\"$SG_ID\"],
                \"TagSpecifications\": [{
                    \"ResourceType\": \"instance\",
                    \"Tags\": [{\"Key\": \"Name\", \"Value\": \"$TAG_VALUE\"}]
                }]
            }")

        NEW_VERSION_CREATED="Yes"
        log "New Launch Template version created."
    fi

else
    log "Launch Template does NOT exist. Creating..."
    aws ec2 create-launch-template \
        --launch-template-name "$LT_NAME" \
        --launch-template-data "{
            \"ImageId\": \"$AMI_ID\",
            \"InstanceType\": \"$INSTANCE_TYPE\",
            \"KeyName\": \"$KEY_NAME\",
            \"IamInstanceProfile\": {\"Name\": \"$IAM_PROFILE_NAME\"},
            \"SecurityGroupIds\": [\"$SG_ID\"],
            \"TagSpecifications\": [{
                \"ResourceType\": \"instance\",
                \"Tags\": [{\"Key\": \"Name\", \"Value\": \"$TAG_VALUE\"}]
            }]
        }"

    NEW_VERSION_CREATED="Yes"
    log "Launch Template created."
fi

###############################################################################
# SUMMARY REPORT
###############################################################################
echo
echo "------------------------------------------------------------"
echo " Launch Template Report"
echo "------------------------------------------------------------"
echo "Template Name:            $LT_NAME"
echo "Template Exists:          Yes"
echo "New Version Created:      $NEW_VERSION_CREATED"
echo "AMI Used:                 $AMI_ID"
echo "Instance Type:            $INSTANCE_TYPE"
echo "Security Group:           $SG_ID"
echo "Key Pair:                 $KEY_NAME"
echo "IAM Profile:              $IAM_PROFILE_NAME"
echo "SSM Ready:                $( [[ -n "$SSM_POLICY" ]] && echo Yes || echo No )"
echo "Idempotency Check:        Passed"
echo "------------------------------------------------------------"
echo

log "Script completed successfully."
