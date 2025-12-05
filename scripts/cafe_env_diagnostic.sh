#!/usr/bin/env bash
#
# cafe_env_diagnostic.sh
#
# READ-ONLY AWS ENVIRONMENT INSPECTION FOR THE CAFE PROJECT
# ---------------------------------------------------------
# Performs full diagnostics of:
# - VPC configuration
# - Subnets & public/private analysis
# - Route table inspection
# - NAT/IGW validation
# - CafeSG security group audit
# - CafeWebAppServer instance reachability
# - Cafe WebServer Image AMI validation
#
# ZERO modifications. Read-only. Safe.
#
# Requirements:
#  - AWS CLI installed and configured
#  - Optional: jq for improved parsing
#

set -euo pipefail

###############
# Utilities
###############

RED="$(tput setaf 1)"
GREEN="$(tput setaf 2)"
YELLOW="$(tput setaf 3)"
BLUE="$(tput setaf 4)"
RESET="$(tput sgr0)"

has_jq=0
if command -v jq >/dev/null 2>&1; then has_jq=1; fi

print_header() {
    echo -e "\n${BLUE}=== $1 ===${RESET}"
}

fail() {
    echo -e "${RED}ERROR:${RESET} $1"
    exit 1
}

warn() {
    echo -e "${YELLOW}WARNING:${RESET} $1"
}

####################################
# 1. AWS CLI + Credentials Check
####################################

print_header "Pre-Flight Checks"

command -v aws >/dev/null 2>&1 || fail "AWS CLI not installed. Install it first."

# Validate CLI config
aws sts get-caller-identity >/dev/null 2>&1 || fail "AWS CLI is not authenticated. Configure credentials."

region=$(aws configure get region)
[[ -z "${region}" ]] && fail "No default region configured. Run: aws configure"

echo -e "${GREEN}AWS CLI OK. Using region: ${region}${RESET}"

####################################
# 2. Identify the Primary VPC
####################################

print_header "VPC Summary"

# Find best candidate VPC (by Name tag if possible)
vpc_json=$(aws ec2 describe-vpcs)
if [[ $has_jq -eq 1 ]]; then
    vpc_id=$(echo "$vpc_json" | jq -r '.Vpcs[] | select(.Tags[]?.Value | contains("Lab")?).VpcId' | head -n1)
fi

# Fallback if jq is not available or tag not found
if [[ -z "${vpc_id:-}" ]]; then
    vpc_id=$(aws ec2 describe-vpcs   --filters "Name=tag:Name,Values=*Lab*"   --query 'Vpcs[0].VpcId' --output text)
fi

[[ "$vpc_id" == "None" ]] && fail "No VPC found."

echo "VPC ID: $vpc_id"

vpc_details=$(aws ec2 describe-vpcs --vpc-ids "$vpc_id" --output json)

cidr=$(echo "$vpc_details" | grep -oE '"CidrBlock": *"[^"]+"' | head -n1 | cut -d'"' -f4)
dns_support=$(aws ec2 describe-vpc-attribute --vpc-id "$vpc_id" --attribute enableDnsSupport --query "EnableDnsSupport.Value" --output text)
dns_hostname=$(aws ec2 describe-vpc-attribute --vpc-id "$vpc_id" --attribute enableDnsHostnames --query "EnableDnsHostnames.Value" --output text)

echo "CIDR Block: $cidr"
echo "DNS Support: $dns_support"
echo "DNS Hostnames: $dns_hostname"

# Internet Gateway
igw_id=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$vpc_id" --query "InternetGateways[0].InternetGatewayId" --output text)

if [[ "$igw_id" == "None" ]]; then
    warn "No Internet Gateway attached to the VPC."
else
    echo "Internet Gateway: $igw_id"
fi

####################################
# 3. Subnet Inspection
####################################

print_header "Subnet Summary"

subnets_json=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc_id")

subnet_ids=$(echo "$subnets_json" | grep -oE '"SubnetId": *"[^"]+"' | cut -d'"' -f4)

for sn in $subnet_ids; do
    echo -e "\nSubnet: $sn"

    name=$(aws ec2 describe-subnets --subnet-ids "$sn" --query "Subnets[0].Tags[?Key=='Name'].Value" --output text)
    cidr=$(aws ec2 describe-subnets --subnet-ids "$sn" --query "Subnets[0].CidrBlock" --output text)
    az=$(aws ec2 describe-subnets --subnet-ids "$sn" --query "Subnets[0].AvailabilityZone" --output text)
    auto_ip=$(aws ec2 describe-subnets --subnet-ids "$sn" --query "Subnets[0].MapPublicIpOnLaunch" --output text)

    echo "  Name: ${name:-<none>}"
    echo "  CIDR: $cidr"
    echo "  AZ:   $az"
    echo "  Auto-assign Public IP: $auto_ip"

    # Determine if subnet is public or private
    rt_id=$(aws ec2 describe-route-tables --filters "Name=association.subnet-id,Values=$sn" --query "RouteTables[0].RouteTableId" --output text)

    if [[ "$rt_id" == "None" ]]; then
        rt_id=$(aws ec2 describe-route-tables --filters "Name=association.main,Values=true" --query "RouteTables[0].RouteTableId" --output text)
    fi

    igw_route=$(aws ec2 describe-route-tables --route-table-ids "$rt_id" --query "RouteTables[0].Routes[?GatewayId=='$igw_id']" --output text 2>/dev/null)

    if [[ -n "$igw_route" ]]; then
        echo "  Subnet Type: PUBLIC"
    else
        echo "  Subnet Type: PRIVATE"
    fi

done

####################################
# 4. Route Table Analysis
####################################
print_header "Route Table Analysis"

rtables=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$vpc_id" --output json)

rt_ids=$(echo "$rtables" | grep -oE '"RouteTableId": *"[^"]+"' | cut -d'"' -f4)

for rt in $rt_ids; do
    echo -e "\nRoute Table: $rt"

    routes=$(aws ec2 describe-route-tables --route-table-ids "$rt" --query "RouteTables[0].Routes" --output json)
    assoc=$(aws ec2 describe-route-tables --route-table-ids "$rt" --query "RouteTables[0].Associations" --output json)

    echo "  Routes:"
    echo "$routes" | sed 's/^/    /'

    echo "  Associated Subnets:"
    echo "$assoc" | sed 's/^/    /'

    # Misconfig detection
    if echo "$routes" | grep -q "$igw_id"; then
        true # IGW exists
    else
        # If a subnet mapped here had auto-IP enabled → warning
        :
    fi
done

####################################
# 5. Security Group: CafeSG
####################################

print_header "Security Group: CafeSG"

sg_id=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=*CafeSG*" --query "SecurityGroups[0].GroupId" --output text)

if [[ "$sg_id" == "None" ]]; then
    warn "Security group 'CafeSG' not found."
else
    echo "Group ID: $sg_id"
    echo "Inbound Rules:"
    aws ec2 describe-security-groups --group-ids "$sg_id" --query "SecurityGroups[0].IpPermissions" --output json

    echo "Outbound Rules:"
    aws ec2 describe-security-groups --group-ids "$sg_id" --query "SecurityGroups[0].IpPermissionsEgress" --output json
fi

####################################
# 6. CafeWebAppServer Instance
####################################

print_header "Instance Reachability: CafeWebAppServer"

instance_id=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=CafeWebAppServer" \
  --query "Reservations[0].Instances[0].InstanceId" --output text)

if [[ "$instance_id" == "None" ]]; then
    warn "Instance 'CafeWebAppServer' not found."
else
    state=$(aws ec2 describe-instances --instance-ids "$instance_id" --query "Reservations[0].Instances[0].State.Name" --output text)
    subnet=$(aws ec2 describe-instances --instance-ids "$instance_id" --query "Reservations[0].Instances[0].SubnetId" --output text)
    public_ip=$(aws ec2 describe-instances --instance-ids "$instance_id" --query "Reservations[0].Instances[0].PublicIpAddress" --output text)

    echo "Instance ID: $instance_id"
    echo "State: $state"
    echo "Subnet: $subnet"
    echo "Public IP: ${public_ip:-None}"

    if [[ "$public_ip" == "None" ]]; then
        echo "Reachability: PRIVATE ONLY (no public IP)"
    else
        echo "Reachability: PUBLICLY REACHABLE (subject to SG rules)"
    fi
fi

####################################
# 7. AMI Verification
####################################

print_header "AMI Verification: Cafe WebServer Image"

ami_id=$(aws ec2 describe-images --owners self \
  --filters "Name=name,Values=Cafe WebServer Image" \
  --query "Images[0].ImageId" --output text)

if [[ "$ami_id" == "None" ]]; then
    warn "AMI 'Cafe WebServer Image' not found."
else
    creation=$(aws ec2 describe-images --image-ids "$ami_id" --query "Images[0].CreationDate" --output text)
    state=$(aws ec2 describe-images --image-ids "$ami_id" --query "Images[0].State" --output text)

    echo "AMI ID: $ami_id"
    echo "Status: $state"
    echo "Created: $creation"
fi

####################################
# 8. Final Warnings Summary
####################################

print_header "Warnings & Potential Misconfigurations"

if [[ "$igw_id" == "None" ]]; then
    warn "VPC has no Internet Gateway — public subnets will not work."
fi

# Detect if NAT gateway missing for AZ2
nat_count=$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$vpc_id" --query "NatGateways" --output json | grep -c NatGatewayId || true)
if (( nat_count < 2 )); then
    warn "You may be missing a NAT gateway for the second Availability Zone."
fi

echo -e "\n${GREEN}Diagnostics complete.${RESET}"

