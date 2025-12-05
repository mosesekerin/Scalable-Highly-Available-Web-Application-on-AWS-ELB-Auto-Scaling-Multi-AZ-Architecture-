#!/usr/bin/env bash
set -euo pipefail

###########################################
#  Fully Automated Application Load Balancer Deployment
#  Discovers all resources automatically (no manual input)
#  For Auto Scaling Group: cafe-asg
###########################################

ASG_NAME="cafe-asg"

log()  { echo -e "\e[1;32m[INFO]\e[0m $*"; }
warn() { echo -e "\e[1;33m[WARN]\e[0m $*"; }
err()  { echo -e "\e[1;31m[ERROR]\e[0m $*" >&2; }

# Validate AWS CLI
command -v aws >/dev/null 2>&1 || { err "AWS CLI not installed"; exit 1; }


###########################################
# Discover VPC from ASG
###########################################
log "Discovering VPC associated with ASG '$ASG_NAME'..."

VPC_ID=$(aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$ASG_NAME" \
    --query "AutoScalingGroups[0].VPCZoneIdentifier" \
    --output text | tr ',' '\n' | head -n1 | xargs -I{} aws ec2 describe-subnets \
    --subnet-ids {} --query "Subnets[0].VpcId" --output text)

if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
    err "Could not determine VPC from ASG '$ASG_NAME'."
    exit 1
fi

log "Detected VPC: $VPC_ID"


###########################################
# Discover PUBLIC SUBNETS (where ALB will live)
###########################################
log "Discovering public subnets (subnets with IGW route)..."

PUBLIC_SUBNETS=$(aws ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'RouteTables[].Associations[?SubnetId!=`null`].SubnetId' \
    --output text | tr '\t' '\n' | while read -r subnet; do
        has_igw=$(aws ec2 describe-route-tables \
            --filters "Name=association.subnet-id,Values=$subnet" \
            --query 'RouteTables[].Routes[?GatewayId!=`null`].GatewayId' \
            --output text | grep -c igw || true)
        if [[ "$has_igw" -gt 0 ]]; then
            echo "$subnet"
        fi
    done)

if [[ -z "$PUBLIC_SUBNETS" ]]; then
    err "No public subnets detected in VPC."
    exit 1
fi

PUB1=$(echo "$PUBLIC_SUBNETS" | sed -n '1p')
PUB2=$(echo "$PUBLIC_SUBNETS" | sed -n '2p')

log "Public subnets detected:"
log " - $PUB1"
log " - $PUB2"


###########################################
# Create ALB Security Group (idempotent)
###########################################
ALB_SG_NAME="Cafe-ALB-SG"

log "Checking for ALB Security Group ($ALB_SG_NAME)..."

ALB_SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=$ALB_SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
    --query "SecurityGroups[0].GroupId" \
    --output text 2>/dev/null || true)

if [[ -z "$ALB_SG_ID" || "$ALB_SG_ID" == "None" ]]; then
    log "Creating ALB Security Group..."
    ALB_SG_ID=$(aws ec2 create-security-group \
        --group-name "$ALB_SG_NAME" \
        --description "Security group for public Application Load Balancer" \
        --vpc-id "$VPC_ID" \
        --query "GroupId" --output text)

    log "Allowing inbound HTTP..."
    aws ec2 authorize-security-group-ingress \
        --group-id "$ALB_SG_ID" \
        --protocol tcp --port 80 --cidr 0.0.0.0/0
else
    log "ALB Security Group already exists: $ALB_SG_ID"
fi


###########################################
# Create Target Group (idempotent)
###########################################
TG_NAME="Cafe-TG"

log "Checking for existing Target Group ($TG_NAME)..."

TG_ARN=$(aws elbv2 describe-target-groups \
    --names "$TG_NAME" \
    --query "TargetGroups[0].TargetGroupArn" \
    --output text 2>/dev/null || true)

if [[ "$TG_ARN" == "None" || -z "$TG_ARN" ]]; then
    log "Creating Target Group..."
    TG_ARN=$(aws elbv2 create-target-group \
        --name "$TG_NAME" \
        --protocol HTTP \
        --port 80 \
        --target-type instance \
        --vpc-id "$VPC_ID" \
        --query "TargetGroups[0].TargetGroupArn" \
        --output text)
else
    log "Target Group already exists: $TG_ARN"
fi


###########################################
# Create ALB (idempotent)
###########################################
ALB_NAME="Cafe-ALB"

log "Checking for existing ALB ($ALB_NAME)..."

ALB_ARN=$(aws elbv2 describe-load-balancers \
    --names "$ALB_NAME" \
    --query "LoadBalancers[0].LoadBalancerArn" \
    --output text 2>/dev/null || true)

if [[ -z "$ALB_ARN" || "$ALB_ARN" == "None" ]]; then
    log "Creating ALB..."
    ALB_ARN=$(aws elbv2 create-load-balancer \
        --name "$ALB_NAME" \
        --subnets "$PUB1" "$PUB2" \
        --security-groups "$ALB_SG_ID" \
        --query "LoadBalancers[0].LoadBalancerArn" \
        --output text)

    log "Waiting for ALB to be active..."
    aws elbv2 wait load-balancer-available --load-balancer-arns "$ALB_ARN"
else
    log "ALB already exists: $ALB_ARN"
fi

ALB_DNS=$(aws elbv2 describe-load-balancers \
    --load-balancer-arns "$ALB_ARN" \
    --query "LoadBalancers[0].DNSName" --output text)


###########################################
# Create Listener 80 → Target Group (idempotent)
###########################################
log "Checking for existing HTTP listeners..."

LISTENER=$(aws elbv2 describe-listeners \
    --load-balancer-arn "$ALB_ARN" \
    --query "Listeners[?Port==\`80\`].ListenerArn" \
    --output text 2>/dev/null || true)

if [[ -n "$LISTENER" ]]; then
    log "Listener already exists: $LISTENER"
else
    log "Creating Listener..."
    aws elbv2 create-listener \
        --load-balancer-arn "$ALB_ARN" \
        --protocol HTTP --port 80 \
        --default-actions Type=forward,TargetGroupArn="$TG_ARN" >/dev/null
fi


###########################################
# Attach Target Group to ASG
###########################################
log "Attaching Target Group to ASG ($ASG_NAME)..."

aws autoscaling attach-load-balancer-target-groups \
    --auto-scaling-group-name "$ASG_NAME" \
    --target-group-arns "$TG_ARN" >/dev/null

log "Target Group successfully attached to ASG."


###########################################
# Output
###########################################
echo ""
log "======================================"
log " ALB SETUP COMPLETE"
log "======================================"
echo "ALB ARN      = $ALB_ARN"
echo "ALB DNS      = http://$ALB_DNS/cafe"
echo "Target Group = $TG_ARN"
echo "SecurityGrp  = $ALB_SG_ID"
echo "======================================"

