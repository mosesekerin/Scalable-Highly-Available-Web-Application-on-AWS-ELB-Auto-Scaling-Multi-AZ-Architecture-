#!/usr/bin/env bash
#
# update-network-multiaz.sh
#
# Description:
#   Automates Step 2 – Updating the Café infrastructure to support Multi-AZ
#   high availability by:
#     - Checking prerequisites
#     - Ensuring NAT Gateway exists in Public Subnet 2 (AZ2)
#     - Allocating EIP when necessary
#     - Updating route table for Private Subnet 2
#     - Producing structured final report
#
# Requirements:
#   - AWS CLI v2
#   - Properly configured AWS profile & region
#   - Subnets named exactly:
#       Public Subnet 2
#       Private Subnet 2
#
# Safety:
#   - Fully idempotent
#   - Does not modify anything except NAT Gateway + Route Table
#

#############################################
#  COLORS
#############################################
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
NC="\e[0m" # No Color

#############################################
#  GLOBAL VARS
#############################################
AWS_REGION=$(aws configure get region)
PROFILE_OK=$(aws configure list | grep -i access_key | wc -l)

NGW_ID=""
EIP_ALLOC_ID=""
RTB_ID=""
PUBLIC_SUBNET_2_ID=""
PRIVATE_SUBNET_2_ID=""
VPC_ID=""

#############################################
#  UTILITY: Error handler
#############################################
fatal() {
    echo -e "${RED}[FATAL] $1${NC}"
    exit 1
}

warn() {
    echo -e "${YELLOW}[WARNING] $1${NC}"
}

info() {
    echo -e "${BLUE}[INFO] $1${NC}"
}

success() {
    echo -e "${GREEN}[SUCCESS] $1${NC}"
}

#############################################
# 1. CHECK PREREQUISITES
#############################################
check_prerequisites() {

    info "Validating prerequisites..."

    command -v aws >/dev/null 2>&1 || fatal "AWS CLI not installed."

    [[ -z "$AWS_REGION" ]] && fatal "No AWS region configured. Run 'aws configure'."

    [[ "$PROFILE_OK" -eq 0 ]] && fatal "AWS profile missing credentials."

    # Discover VPC
    VPC_ID=$(aws ec2 describe-vpcs   --filters "Name=tag:Name,Values=*Lab*"   --query 'Vpcs[0].VpcId' --output text)

    [[ "$VPC_ID" == "None" || -z "$VPC_ID" ]] && fatal "Could not find any VPC."

    info "VPC detected: $VPC_ID"

    # Get Public Subnet 2
    PUBLIC_SUBNET_2_ID=$(aws ec2 describe-subnets \
        --filters "Name=tag:Name,Values=Public Subnet 2" \
        --query "Subnets[0].SubnetId" \
        --output text)

    [[ "$PUBLIC_SUBNET_2_ID" == "None" || -z "$PUBLIC_SUBNET_2_ID" ]] && \
        fatal "Public Subnet 2 not found."

    info "Public Subnet 2: $PUBLIC_SUBNET_2_ID"

    # Get Private Subnet 2
    PRIVATE_SUBNET_2_ID=$(aws ec2 describe-subnets \
        --filters "Name=tag:Name,Values=Private Subnet 2" \
        --query "Subnets[0].SubnetId" \
        --output text)

    [[ "$PRIVATE_SUBNET_2_ID" == "None" || -z "$PRIVATE_SUBNET_2_ID" ]] && \
        fatal "Private Subnet 2 not found."

    info "Private Subnet 2: $PRIVATE_SUBNET_2_ID"

    # Validate IGW exists
    IGW_ID=$(aws ec2 describe-internet-gateways \
        --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
        --query "InternetGateways[0].InternetGatewayId" \
        --output text)

    [[ "$IGW_ID" == "None" || -z "$IGW_ID" ]] && \
        fatal "No Internet Gateway found for this VPC."

    info "Internet Gateway: $IGW_ID"

    # Validate Public Subnet 2 has auto-assign public IP
    AUTO_ASSIGN=$(aws ec2 describe-subnets \
        --subnet-ids "$PUBLIC_SUBNET_2_ID" \
        --query "Subnets[0].MapPublicIpOnLaunch" \
        --output text)

    [[ "$AUTO_ASSIGN" != "True" ]] && \
        fatal "Public Subnet 2 is NOT configured to auto-assign public IPs."

    info "Public Subnet 2 auto-assign public IP: OK"

    # Public Subnet 2 must have default route to IGW
    PUB_RTB_ID=$(aws ec2 describe-route-tables \
        --filters "Name=association.subnet-id,Values=$PUBLIC_SUBNET_2_ID" \
        --query "RouteTables[0].RouteTableId" \
        --output text)

    if [[ "$PUB_RTB_ID" == "None" ]]; then
        # Fallback: main route table
        PUB_RTB_ID=$(aws ec2 describe-route-tables \
            --filters "Name=association.main,Values=true" \
            --query "RouteTables[0].RouteTableId" \
            --output text)
    fi

    IGW_ROUTE=$(aws ec2 describe-route-tables \
        --route-table-ids "$PUB_RTB_ID" \
        --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].GatewayId" \
        --output text)

    [[ "$IGW_ROUTE" != "$IGW_ID" ]] && fatal "Public Subnet 2 route table has no IGW default route."

    success "Prerequisites validated."
}

#############################################
# 2. NAT GATEWAY CREATION (IDEMPOTENT)
#############################################
create_nat_gateway() {
    info "Checking for existing NAT Gateway in Public Subnet 2..."

    NGW_ID=$(aws ec2 describe-nat-gateways \
        --filter "Name=subnet-id,Values=$PUBLIC_SUBNET_2_ID" \
        --query "NatGateways[?State=='available'].NatGatewayId" \
        --output text)

    if [[ "$NGW_ID" != "None" && -n "$NGW_ID" ]]; then
        success "NAT Gateway already exists: $NGW_ID"
        return
    fi

    info "No existing NAT Gateway found. Creating new one..."

    # Allocate EIP
    EIP_ALLOC_ID=$(aws ec2 allocate-address \
        --domain vpc \
        --query "AllocationId" \
        --output text) || fatal "EIP allocation failed."

    info "Elastic IP allocated: $EIP_ALLOC_ID"

    # Create NAT Gateway
    NGW_ID=$(aws ec2 create-nat-gateway \
        --subnet-id "$PUBLIC_SUBNET_2_ID" \
        --allocation-id "$EIP_ALLOC_ID" \
        --query "NatGateway.NatGatewayId" \
        --output text) || fatal "Failed to create NAT Gateway."

    info "NAT Gateway created: $NGW_ID"

    wait_for_nat
}

#############################################
# 3. WAIT FOR NAT GATEWAY
#############################################
wait_for_nat() {
    info "Waiting for NAT Gateway to become AVAILABLE..."

    while true; do
        STATE=$(aws ec2 describe-nat-gateways \
            --nat-gateway-ids "$NGW_ID" \
            --query "NatGateways[0].State" \
            --output text)

        if [[ "$STATE" == "available" ]]; then
            success "NAT Gateway is available."
            break
        elif [[ "$STATE" == "failed" ]]; then
            fatal "NAT Gateway failed to initialize."
        else
            echo -e "${YELLOW}  → Current state: $STATE (waiting)...${NC}"
            sleep 10
        fi
    done
}

#############################################
# 4. UPDATE ROUTE TABLE FOR PRIVATE SUBNET 2
#############################################
update_route_table() {

    info "Locating route table for Private Subnet 2..."

    RTB_ID=$(aws ec2 describe-route-tables \
        --filters "Name=association.subnet-id,Values=$PRIVATE_SUBNET_2_ID" \
        --query "RouteTables[0].RouteTableId" \
        --output text)

    [[ "$RTB_ID" == "None" || -z "$RTB_ID" ]] && fatal "Could not locate route table for Private Subnet 2."

    info "Private Subnet 2 Route Table: $RTB_ID"

    # Check route
    CURRENT_TARGET=$(aws ec2 describe-route-tables \
        --route-table-ids "$RTB_ID" \
        --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].NatGatewayId" \
        --output text)

    if [[ "$CURRENT_TARGET" == "$NGW_ID" ]]; then
        success "Route already correctly points to NAT Gateway."
        ROUTE_UPDATED="NO"
        return
    fi

    info "Updating route table default route to use NAT Gateway..."

    # Delete conflicting default routes
    aws ec2 delete-route \
        --route-table-id "$RTB_ID" \
        --destination-cidr-block "0.0.0.0/0" 2>/dev/null

    sleep 2

    # Create correct route
    aws ec2 create-route \
        --route-table-id "$RTB_ID" \
        --destination-cidr-block "0.0.0.0/0" \
        --nat-gateway-id "$NGW_ID" \
        >/dev/null 2>&1 || fatal "Failed to create new default route."

    success "Route table updated."
    ROUTE_UPDATED="YES"
}

#############################################
# 5. FINAL REPORT
#############################################
final_report() {
    echo -e "\n${GREEN}================ Multi-AZ Network Update Report ================${NC}"
    echo "VPC Found:                   YES ($VPC_ID)"
    echo "Public Subnet 2:             $PUBLIC_SUBNET_2_ID"
    echo "Private Subnet 2:            $PRIVATE_SUBNET_2_ID"
    echo "Elastic IP:                  ${EIP_ALLOC_ID:-'Existing EIP'}"
    echo "NAT Gateway:                 $NGW_ID (status: available)"
    echo "Route Table (Private Sub 2): $RTB_ID"
    echo "Default Route Updated:       ${ROUTE_UPDATED}"
    echo "Private Subnet 2 Internet:   ENABLED"
    echo -e "===============================================================${NC}\n"
}

#############################################
#  MAIN
#############################################
check_prerequisites
create_nat_gateway
update_route_table
final_report

