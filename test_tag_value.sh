#!/bin/bash

# Test script to check tag values on a specific subnet
# Usage: ./test_tag_value.sh SUBNET_ID TAG_KEY [REGION]

set -euo pipefail

SUBNET_ID="${1:-}"
TAG_KEY="${2:-}"
REGION="${3:-$(aws configure get region 2>/dev/null || echo 'us-west-2')}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

if [[ -z "$SUBNET_ID" || -z "$TAG_KEY" ]]; then
    echo -e "${RED}Usage: $0 SUBNET_ID TAG_KEY [REGION]${NC}"
    echo "Example: $0 subnet-12345 kubernetes.io/cluster"
    exit 1
fi

echo -e "${GREEN}Checking tag '$TAG_KEY' on subnet '$SUBNET_ID' in region '$REGION'${NC}"

# Get the tag value
TAG_VALUE=$(aws ec2 describe-tags \
    --region "$REGION" \
    --filters "Name=resource-id,Values=$SUBNET_ID" "Name=key,Values=$TAG_KEY" \
    --query 'Tags[0].Value' \
    --output text 2>/dev/null || echo "")

if [[ -z "$TAG_VALUE" || "$TAG_VALUE" == "None" ]]; then
    echo -e "${YELLOW}Tag '$TAG_KEY' not found on subnet '$SUBNET_ID'${NC}"
else
    echo -e "${GREEN}Tag '$TAG_KEY' found with value: '$TAG_VALUE'${NC}"
    echo -e "${BLUE}Value length: ${#TAG_VALUE} characters${NC}"
    echo -e "${BLUE}Value bytes: $(echo -n "$TAG_VALUE" | xxd -p)${NC}"
fi

# Also show all tags for this subnet
echo
echo -e "${BLUE}All tags on subnet '$SUBNET_ID':${NC}"
aws ec2 describe-tags \
    --region "$REGION" \
    --filters "Name=resource-id,Values=$SUBNET_ID" \
    --query 'Tags[].[Key,Value]' \
    --output table 2>/dev/null || echo "No tags found"
