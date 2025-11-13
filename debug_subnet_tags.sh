#!/bin/bash

# Debug script to show all tags on subnets
# Usage: ./debug_subnet_tags.sh [--subnet-ids ID1,ID2] [--region REGION] [--tag-key KEY]

set -euo pipefail

# Default values
REGION=""
SUBNET_IDS=""
TAG_KEY=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Help function
show_help() {
    cat << EOF
Debug script to show all tags on subnets

Usage: $0 [OPTIONS]

OPTIONS:
    --subnet-ids IDS        Comma-separated list of subnet IDs (default: all subnets)
    --region REGION         AWS region (default: current region)
    --tag-key KEY           Show only specific tag key
    -h, --help              Show this help message

EXAMPLES:
    # Show all tags on all subnets
    $0

    # Show all tags on specific subnets
    $0 --subnet-ids subnet-12345,subnet-67890

    # Show only specific tag key
    $0 --tag-key kubernetes.io/cluster
EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --subnet-ids)
            SUBNET_IDS="$2"
            shift 2
            ;;
        --region)
            REGION="$2"
            shift 2
            ;;
        --tag-key)
            TAG_KEY="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            show_help
            exit 1
            ;;
    esac
done

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
    echo -e "${RED}Error: AWS CLI not found${NC}"
    exit 1
fi

# Check AWS credentials
if ! aws sts get-caller-identity &> /dev/null; then
    echo -e "${RED}Error: AWS credentials not configured${NC}"
    exit 1
fi

# Set region if not specified
if [[ -z "$REGION" ]]; then
    REGION=$(aws configure get region)
    if [[ -z "$REGION" ]]; then
        echo -e "${RED}Error: No AWS region configured${NC}"
        exit 1
    fi
fi

echo -e "${GREEN}Debugging tags on subnets in region: $REGION${NC}"

# Function to get all subnets if subnet-ids not specified
get_all_subnets() {
    local subnets=$(aws ec2 describe-subnets \
        --region "$REGION" \
        --query 'Subnets[].SubnetId' \
        --output text 2>/dev/null || true)
    
    if [[ -z "$subnets" ]]; then
        echo -e "${YELLOW}No subnets found in region $REGION${NC}"
        return 1
    fi
    
    echo "$subnets"
}

# Function to get subnet details
get_subnet_details() {
    local subnet_id="$1"
    
    aws ec2 describe-subnets \
        --region "$REGION" \
        --subnet-ids "$subnet_id" \
        --query 'Subnets[0].[SubnetId,VpcId,AvailabilityZone,CidrBlock,Tags]' \
        --output json 2>/dev/null || echo "null"
}

# Function to show tags for a subnet
show_subnet_tags() {
    local subnet_id="$1"
    local tag_key_filter="$2"
    
    local subnet_info=$(get_subnet_details "$subnet_id")
    if [[ "$subnet_info" == "null" ]]; then
        echo -e "${RED}Could not retrieve details for subnet: $subnet_id${NC}"
        return 1
    fi
    
    local vpc_id=$(echo "$subnet_info" | jq -r '.[1]')
    local az=$(echo "$subnet_info" | jq -r '.[2]')
    local cidr=$(echo "$subnet_info" | jq -r '.[3]')
    local tags=$(echo "$subnet_info" | jq -r '.[4] // []')
    
    echo
    echo "=========================================="
    echo "Subnet: $subnet_id"
    echo "VPC: $vpc_id | AZ: $az | CIDR: $cidr"
    echo "=========================================="
    
    if [[ "$tags" == "[]" ]]; then
        echo "No tags found"
        return 0
    fi
    
    # Show all tags or filter by key
    if [[ -n "$tag_key_filter" ]]; then
        echo "Tags with key '$tag_key_filter':"
        echo "$tags" | jq -r --arg key "$tag_key_filter" '.[] | select(.Key == $key) | "  \(.Key): \(.Value)"' 2>/dev/null || echo "  (No tags with key '$tag_key_filter')"
    else
        echo "All tags:"
        echo "$tags" | jq -r '.[] | "  \(.Key): \(.Value)"' 2>/dev/null || echo "  (Unable to parse tags)"
    fi
}

# Main execution
main() {
    # Determine subnets to process
    local subnets_to_process=""
    if [[ -n "$SUBNET_IDS" ]]; then
        # Convert comma-separated to space-separated
        subnets_to_process=$(echo "$SUBNET_IDS" | tr ',' ' ')
    else
        # Get all subnets
        subnets_to_process=$(get_all_subnets)
        if [[ $? -ne 0 ]]; then
            exit 1
        fi
    fi
    
    # Count subnets
    local subnet_count=$(echo "$subnets_to_process" | wc -w)
    echo -e "${BLUE}Processing $subnet_count subnet(s)${NC}"
    
    # Process each subnet
    for subnet in $subnets_to_process; do
        show_subnet_tags "$subnet" "$TAG_KEY"
    done
    
    echo
    echo "=========================================="
    echo "Debug complete"
    echo "=========================================="
}

# Run main function
main
