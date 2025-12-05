#!/usr/bin/env bash
set -euo pipefail

#############################################
# Multi-AZ Highly Available Cafe ASG Creator
# Pure Bash + AWS CLI (Production-grade)
#############################################

### -------- CONFIGURABLE PARAMETERS -------- ###
PROJECT="cafe"
ENVIRONMENT="prod"
OWNER="devops-team"
COST_CENTER="caf-001"

ASG_NAME="${PROJECT}-asg"
LAUNCH_TEMPLATE_NAME="CafeWebServer-LT"
TARGET_POLICY_NAME="${PROJECT}-cpu-policy"

DESIRED_CAPACITY=2
MIN_CAPACITY=2
MAX_CAPACITY=6
TARGET_CPU=25
INSTANCE_WARMUP=60

### -------- INTERNAL FUNCTIONS -------- ###

err() {
    echo -e "\e[91mERROR: $1\e[0m" >&2
    exit 1
}

info() {
    echo -e "\e[96mINFO: $1\e[0m"
}

success() {
    echo -e "\e[92mSUCCESS: $1\e[0m"
}

### -------- VALIDATION: LAUNCH TEMPLATE -------- ###
info "Validating Launch Template: $LAUNCH_TEMPLATE_NAME ..."
LT_ID=$(aws ec2 describe-launch-templates \
    --query "LaunchTemplates[?LaunchTemplateName=='$LAUNCH_TEMPLATE_NAME'].LaunchTemplateId" \
    --output text)

[[ "$LT_ID" == "None" || -z "$LT_ID" ]] && err "Launch template '$LAUNCH_TEMPLATE_NAME' not found."

success "Launch Template found: $LT_ID"


### -------- VALIDATION: PRIVATE SUBNET 1 & 2 -------- ###
info "Resolving Private Subnet 1 & 2 from Name tags..."

SUBNET1=$(aws ec2 describe-subnets \
    --filters "Name=tag:Name,Values=Private Subnet 1" \
    --query "Subnets[0].SubnetId" \
    --output text)

SUBNET2=$(aws ec2 describe-subnets \
    --filters "Name=tag:Name,Values=Private Subnet 2" \
    --query "Subnets[0].SubnetId" \
    --output text)

[[ -z "$SUBNET1" || "$SUBNET1" == "None" ]] && err "Private Subnet 1 not found (tag: Name=Private Subnet 1)."
[[ -z "$SUBNET2" || "$SUBNET2" == "None" ]] && err "Private Subnet 2 not found (tag: Name=Private Subnet 2)."

success "Found Private Subnet 1: $SUBNET1"
success "Found Private Subnet 2: $SUBNET2"

AZ1=$(aws ec2 describe-subnets --subnet-ids "$SUBNET1" --query "Subnets[0].AvailabilityZone" --output text)
AZ2=$(aws ec2 describe-subnets --subnet-ids "$SUBNET2" --query "Subnets[0].AvailabilityZone" --output text)

[[ "$AZ1" == "$AZ2" ]] && err "Private Subnet 1 & 2 must be in different AZs. Found both in: $AZ1"

success "Subnets are in different AZs: $AZ1 and $AZ2"


### -------- VALIDATION: VPC -------- ###
info "Validating VPC ID from private subnets..."

VPC_ID=$(aws ec2 describe-subnets --subnet-ids "$SUBNET1" --query "Subnets[0].VpcId" --output text)

[[ -z "$VPC_ID" || "$VPC_ID" == "None" ]] && err "Unable to determine VPC ID."

success "VPC: $VPC_ID"


### -------- VALIDATION: NAT GATEWAY ROUTES -------- ###
info "Validating NAT Gateways in BOTH AZs..."

for subnet in "$SUBNET1" "$SUBNET2"; do
    RT_ID=$(aws ec2 describe-route-tables \
        --filters "Name=association.subnet-id,Values=$subnet" \
        --query "RouteTables[0].RouteTableId" --output text)

    [[ "$RT_ID" == "None" || -z "$RT_ID" ]] && err "Subnet $subnet has no associated route table."

    NAT_TARGET=$(aws ec2 describe-route-tables \
        --route-table-ids "$RT_ID" \
        --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].NatGatewayId" \
        --output text)

    [[ "$NAT_TARGET" == "None" || -z "$NAT_TARGET" ]] && err "Subnet $subnet has NO NAT route → private instances will lose outbound connectivity."
done

success "NAT reachability verified in both private subnets."


### -------- CREATE OR UPDATE ASG -------- ###
info "Checking if ASG '$ASG_NAME' already exists..."

ASG_EXISTS=$(aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$ASG_NAME" \
    --query "AutoScalingGroups[*].AutoScalingGroupName" \
    --output text)

if [[ -z "$ASG_EXISTS" ]]; then
    info "ASG not found — creating new ASG..."

    aws autoscaling create-auto-scaling-group \
        --auto-scaling-group-name "$ASG_NAME" \
        --launch-template "LaunchTemplateName=$LAUNCH_TEMPLATE_NAME" \
        --min-size "$MIN_CAPACITY" \
        --max-size "$MAX_CAPACITY" \
        --desired-capacity "$DESIRED_CAPACITY" \
        --vpc-zone-identifier "$SUBNET1,$SUBNET2" \
        --health-check-type EC2 \
        --health-check-grace-period 300 \
        --tags "Key=Name,Value=${PROJECT}-webserver,PropagateAtLaunch=true" \
               "Key=Environment,Value=$ENVIRONMENT,PropagateAtLaunch=true" \
               "Key=Project,Value=$PROJECT,PropagateAtLaunch=true" \
               "Key=Owner,Value=$OWNER,PropagateAtLaunch=true" \
               "Key=CostCenter,Value=$COST_CENTER,PropagateAtLaunch=true" \
               "Key=AutoScaling,Value=true,PropagateAtLaunch=true"

    success "ASG created successfully."
else
    info "ASG exists — updating configuration..."

    aws autoscaling update-auto-scaling-group \
        --auto-scaling-group-name "$ASG_NAME" \
        --launch-template "LaunchTemplateName=$LAUNCH_TEMPLATE_NAME" \
        --min-size "$MIN_CAPACITY" \
        --max-size "$MAX_CAPACITY" \
        --desired-capacity "$DESIRED_CAPACITY" \
        --vpc-zone-identifier "$SUBNET1,$SUBNET2"

    success "ASG updated successfully."
fi


### -------- CREATE OR UPDATE TARGET TRACKING POLICY -------- ###
info "Ensuring scaling policy exists..."

POLICY_EXISTS=$(aws autoscaling describe-policies \
    --auto-scaling-group-name "$ASG_NAME" \
    --query "ScalingPolicies[?PolicyName=='$TARGET_POLICY_NAME'].PolicyName" \
    --output text)

if [[ -z "$POLICY_EXISTS" ]]; then
    info "Creating new Target Tracking Scaling Policy..."

    aws autoscaling put-scaling-policy \
        --policy-name "$TARGET_POLICY_NAME" \
        --auto-scaling-group-name "$ASG_NAME" \
        --policy-type "TargetTrackingScaling" \
        --target-tracking-configuration "TargetValue=$TARGET_CPU,PredefinedMetricSpecification={PredefinedMetricType=ASGAverageCPUUtilization},DisableScaleIn=false" \
        --estimated-instance-warmup "$INSTANCE_WARMUP"

    success "Scaling policy created."
else
    info "Policy exists — updating scaling policy..."

    aws autoscaling put-scaling-policy \
        --policy-name "$TARGET_POLICY_NAME" \
        --auto-scaling-group-name "$ASG_NAME" \
        --policy-type "TargetTrackingScaling" \
        --target-tracking-configuration "TargetValue=$TARGET_CPU,PredefinedMetricSpecification={PredefinedMetricType=ASGAverageCPUUtilization},DisableScaleIn=false" \
        --estimated-instance-warmup "$INSTANCE_WARMUP"

    success "Scaling policy updated."
fi

success "AUTO SCALING GROUP PROVISIONED AND VALIDATED."

