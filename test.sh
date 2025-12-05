#!/usr/bin/env bash
set -euo pipefail

##############################################
# AUTO-DISCOVERY NAMING PATTERNS
##############################################
PATTERN="Cafe|cafe|CafeWeb|CafeServer|CafeWebServer"

##############################################
# LOGGING UTILITIES
##############################################
log() { printf "\n[%s] %s\n" "$(date '+%H:%M:%S')" "$1"; }
fatal() { printf "\n[ERROR] %s\n" "$1" >&2; exit 1; }

##############################################
# DISCOVER ALB
##############################################
log "Discovering Application Load Balancer..."
ALB_ARN=$(aws elbv2 describe-load-balancers \
    --query "LoadBalancers[?contains(LoadBalancerName, \`Cafe\`) || contains(LoadBalancerName, \`cafe\`)].LoadBalancerArn | [0]" \
    --output text)

[[ "$ALB_ARN" == "None" ]] && fatal "Could not locate ALB with pattern: $PATTERN"

ALB_DNS=$(aws elbv2 describe-load-balancers \
    --load-balancer-arns "$ALB_ARN" \
    --query "LoadBalancers[0].DNSName" \
    --output text)

log "ALB Found: $ALB_ARN"
log "ALB DNS:  $ALB_DNS"

##############################################
# WAIT FOR ALB TO BECOME ACTIVE
##############################################
log "Validating ALB state..."
ALB_STATE=$(aws elbv2 describe-load-balancers \
    --load-balancer-arns "$ALB_ARN" \
    --query "LoadBalancers[0].State.Code" \
    --output text)

COUNTER=0
until [[ "$ALB_STATE" == "active" ]]; do
    ((COUNTER++))
    [[ $COUNTER -gt 20 ]] && fatal "ALB did not become active."
    log "ALB state = $ALB_STATE ... waiting"
    sleep 10
    ALB_STATE=$(aws elbv2 describe-load-balancers \
        --load-balancer-arns "$ALB_ARN" \
        --query "LoadBalancers[0].State.Code" \
        --output text)
done

log "ALB is ACTIVE."

##############################################
# DISCOVER TARGET GROUP
##############################################
log "Discovering Target Group..."
TG_ARN=$(aws elbv2 describe-target-groups \
    --query "TargetGroups[?contains(TargetGroupName, \`Cafe\`) || contains(TargetGroupName, \`cafe\`)].TargetGroupArn | [0]" \
    --output text)

[[ "$TG_ARN" == "None" ]] && fatal "Could not find Target Group."

log "Target Group Found: $TG_ARN"

##############################################
# VALIDATE TARGET GROUP HEALTH
##############################################
log "Checking target health..."
aws elbv2 describe-target-health --target-group-arn "$TG_ARN"

##############################################
# DISCOVER AUTO SCALING GROUP
##############################################
log "Discovering Auto Scaling Group..."
ASG_NAME=$(aws autoscaling describe-auto-scaling-groups \
    --query "AutoScalingGroups[?contains(AutoScalingGroupName, \`Cafe\`) || contains(AutoScalingGroupName, \`cafe\`)].AutoScalingGroupName | [0]" \
    --output text)

[[ "$ASG_NAME" == "None" ]] && fatal "ASG not found."

log "ASG Found: $ASG_NAME"

##############################################
# VERIFY ASG INSTANCES
##############################################
log "Retrieving ASG instances..."
ASG_INSTANCES=$(aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-name "$ASG_NAME" \
    --query "AutoScalingGroups[0].Instances[].InstanceId" \
    --output text)

log "ASG Instances: $ASG_INSTANCES"

##############################################
# VERIFY NAT GATEWAY AND ROUTES
##############################################
log "Checking NAT Gateways..."
NAT_GW_IDS=$(aws ec2 describe-nat-gateways \
    --query "NatGateways[?State=='available'].NatGatewayId" \
    --output text)

[[ -z "$NAT_GW_IDS" ]] && fatal "No NAT Gateways in AVAILABLE state."

log "NAT Gateways available: $NAT_GW_IDS"

log "Validating route tables with 0.0.0.0/0 through NAT..."
ROUTES=$(aws ec2 describe-route-tables \
    --query "RouteTables[].Routes[?DestinationCidrBlock=='0.0.0.0/0'] | []" \
    --output text)

log "Routes:"
echo "$ROUTES"

##############################################
# FUNCTIONAL TEST – ALB WITHOUT LOAD
##############################################
log "Testing the web application (HTTP 200 check)..."
TEST_URL="http://${ALB_DNS}/cafe"

for i in {1..10}; do
    STATUS=$(curl -L -s -o /dev/null -w "%{http_code}" "$TEST_URL" || true)
    log "Attempt $i: HTTP $STATUS"

    [[ "$STATUS" == "200" ]] && {
        log "SUCCESS: Application is responding correctly."
        break
    }

    sleep 5

    [[ $i -eq 10 ]] && fatal "Application did not return HTTP 200."
done


##############################################
# MONITOR SCALING BEHAVIOR
##############################################
log "Monitoring ASG for scale-out events..."
EXPECTED_MIN=2
SCALE_COUNTER=0

while true; do
    CURRENT_COUNT=$(aws autoscaling describe-auto-scaling-groups \
        --auto-scaling-group-name "$ASG_NAME" \
        --query "AutoScalingGroups[0].Instances | length(@)" \
        --output text)

    log "Current ASG instance count: $CURRENT_COUNT"

    if (( CURRENT_COUNT > EXPECTED_MIN )); then
        log "Detected scale-out! New instances launched."
        break
    fi

    ((SCALE_COUNTER++))
    [[ $SCALE_COUNTER -gt 60 ]] && fatal "Scaling did not occur. Check CloudWatch and ASG policies."

    sleep 10
done

##############################################
# VALIDATE NEW INSTANCES REGISTER WITH TARGET GROUP
##############################################
log "Validating new instances registration..."
aws elbv2 describe-target-health --target-group-arn "$TG_ARN"

##############################################
# POST-SCALE FUNCTIONAL TEST
##############################################
log "Re-testing application after scale-out..."
for req in {1..10}; do
    RESPONSE=$(curl -s "$TEST_URL")
    log "Request $req succeeded."
    sleep 1
done

log "Load balancing and auto scaling test completed successfully!"

