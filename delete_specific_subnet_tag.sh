#!/bin/bash

# Script to delete a specific tag from AWS subnets (optionally with specific value)
# Usage: ./delete_specific_subnet_tag.sh --tag-key KEY [--tag-value VALUE] --subnet-ids ID1,ID2 [--region REGION] [--dry-run]

set -euo pipefail

# Default values
REGION=""
SUBNET_IDS=""
TAG_KEY=""
TAG_VALUE=""
DRY_RUN=false
VERBOSE=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_debug() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo -e "${BLUE}[DEBUG]${NC} $1"
    fi
}

# Help function
show_help() {
    cat << EOF
Usage: $0 --tag-key KEY [OPTIONS]

Delete a specific tag from AWS subnets (optionally with specific value)

REQUIRED:
    --tag-key KEY           Tag key to delete

OPTIONS:
    --tag-value VALUE       Only delete tag if it has this specific value
    --subnet-ids IDS        Comma-separated list of subnet IDs (default: all subnets)
    --region REGION         AWS region (default: current region)
    --dry-run               Show what would be deleted without actually deleting
    --verbose               Enable verbose output
    -h, --help              Show this help message

EXAMPLES:
    # Delete 'Environment' tag from specific subnets
    $0 --tag-key Environment --subnet-ids subnet-12345,subnet-67890

    # Delete 'Environment' tag only if value is 'dev'
    $0 --tag-key Environment --tag-value dev --subnet-ids subnet-12345,subnet-67890

    # Delete 'Project' tag from all subnets in region
    $0 --tag-key Project --region us-west-2

    # Dry run to see what would be deleted
    $0 --tag-key Environment --tag-value test --dry-run
EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --tag-key)
            TAG_KEY="$2"
            shift 2
            ;;
        --tag-value)
            TAG_VALUE="$2"
            shift 2
            ;;
        --subnet-ids)
            SUBNET_IDS="$2"
            shift 2
            ;;
        --region)
            REGION="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Validate required parameters
if [[ -z "$TAG_KEY" ]]; then
    log_error "Tag key is required. Use --tag-key to specify the tag to delete."
    show_help
    exit 1
fi

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
    log_error "AWS CLI is not installed. Please install it first."
    exit 1
fi

# Check AWS credentials
if ! aws sts get-caller-identity &> /dev/null; then
    log_error "AWS credentials not configured. Please run 'aws configure' first."
    exit 1
fi

# Set region if not specified
if [[ -z "$REGION" ]]; then
    REGION=$(aws configure get region)
    if [[ -z "$REGION" ]]; then
        log_error "No AWS region configured. Please specify --region or run 'aws configure'"
        exit 1
    fi
fi

log_info "Operating in region: $REGION"
log_info "Tag key to delete: $TAG_KEY"
if [[ -n "$TAG_VALUE" ]]; then
    log_info "Tag value filter: $TAG_VALUE"
fi

# Function to get all subnets if subnet-ids not specified
get_all_subnets() {
    log_info "Fetching all subnets in region $REGION..."
    
    local subnets=$(aws ec2 describe-subnets \
        --region "$REGION" \
        --query 'Subnets[].SubnetId' \
        --output text 2>/dev/null || true)
    
    if [[ -z "$subnets" ]]; then
        log_warn "No subnets found in region $REGION"
        return 1
    fi
    
    echo "$subnets"
}

# Function to check if tag exists on subnet
check_tag_exists() {
    local subnet_id="$1"
    local tag_key="$2"
    local tag_value="$3"
    
    local tags=$(aws ec2 describe-tags \
        --region "$REGION" \
        --filters "Name=resource-id,Values=$subnet_id" "Name=key,Values=$tag_key" \
        --query 'Tags[0]' \
        --output json 2>/dev/null || echo "null")
    
    if [[ "$tags" == "null" ]]; then
        return 1  # Tag doesn't exist
    fi
    
    local found_key=$(echo "$tags" | jq -r '.Key' 2>/dev/null || echo "")
    if [[ "$found_key" != "$tag_key" ]]; then
        return 1  # Tag doesn't exist
    fi
    
    # If tag value filter is specified, check the value
    if [[ -n "$tag_value" ]]; then
        local found_value=$(echo "$tags" | jq -r '.Value' 2>/dev/null || echo "")
        if [[ "$found_value" != "$tag_value" ]]; then
            return 1  # Tag exists but value doesn't match
        fi
    fi
    
    return 0  # Tag exists (and value matches if specified)
}

# Function to get tag value
get_tag_value() {
    local subnet_id="$1"
    local tag_key="$2"
    
    aws ec2 describe-tags \
        --region "$REGION" \
        --filters "Name=resource-id,Values=$subnet_id" "Name=key,Values=$tag_key" \
        --query 'Tags[0].Value' \
        --output text 2>/dev/null || echo ""
}

# Function to delete tag from subnet
delete_tag_from_subnet() {
    local subnet_id="$1"
    local tag_key="$2"
    local tag_value_filter="$3"
    
    log_debug "Checking subnet: $subnet_id"
    
    # Check if tag exists (with value filter if specified)
    if ! check_tag_exists "$subnet_id" "$tag_key" "$tag_value_filter"; then
        if [[ -n "$tag_value_filter" ]]; then
            log_debug "Tag '$tag_key' with value '$tag_value_filter' not found on subnet $subnet_id"
        else
            log_debug "Tag '$tag_key' not found on subnet $subnet_id"
        fi
        return 0
    fi
    
    # Get current tag value for display
    local current_tag_value=$(get_tag_value "$subnet_id" "$tag_key")
    
    if [[ "$DRY_RUN" == "true" ]]; then
        if [[ -n "$tag_value_filter" ]]; then
            log_info "DRY RUN: Would delete tag '$tag_key' (value: '$current_tag_value') from subnet $subnet_id (matches filter: '$tag_value_filter')"
        else
            log_info "DRY RUN: Would delete tag '$tag_key' (value: '$current_tag_value') from subnet $subnet_id"
        fi
        return 0
    fi
    
    # Delete the tag
    if [[ -n "$tag_value_filter" ]]; then
        log_info "Deleting tag '$tag_key' (value: '$current_tag_value') from subnet $subnet_id (matches filter: '$tag_value_filter')"
    else
        log_info "Deleting tag '$tag_key' (value: '$current_tag_value') from subnet $subnet_id"
    fi
    
    if aws ec2 delete-tags \
        --region "$REGION" \
        --resources "$subnet_id" \
        --tags "Key=$tag_key" 2>/dev/null; then
        log_info "Successfully deleted tag '$tag_key' from subnet $subnet_id"
        return 0
    else
        log_error "Failed to delete tag '$tag_key' from subnet $subnet_id"
        return 1
    fi
}

# Function to display subnet summary
display_subnet_summary() {
    local subnet_id="$1"
    local tag_key="$2"
    local tag_value_filter="$3"
    
    if check_tag_exists "$subnet_id" "$tag_key" "$tag_value_filter"; then
        local tag_value=$(get_tag_value "$subnet_id" "$tag_key")
        if [[ -n "$tag_value_filter" ]]; then
            echo "  ✓ $subnet_id: $tag_key = '$tag_value' (matches filter: '$tag_value_filter')"
        else
            echo "  ✓ $subnet_id: $tag_key = '$tag_value'"
        fi
        return 0
    else
        local tag_value=$(get_tag_value "$subnet_id" "$tag_key")
        if [[ -n "$tag_value" ]]; then
            if [[ -n "$tag_value_filter" ]]; then
                echo "  - $subnet_id: $tag_key = '$tag_value' (doesn't match filter: '$tag_value_filter')"
            else
                echo "  - $subnet_id: $tag_key = '$tag_value' (not found)"
            fi
        else
            echo "  - $subnet_id: $tag_key (not found)"
        fi
        return 1
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
    log_info "Processing $subnet_count subnet(s)"
    
    # Show current state
    echo
    echo "=========================================="
    echo "CURRENT TAG STATE"
    echo "=========================================="
    local found_count=0
    for subnet in $subnets_to_process; do
        if display_subnet_summary "$subnet" "$TAG_KEY" "$TAG_VALUE"; then
            ((found_count++))
        fi
    done
    echo "=========================================="
    if [[ -n "$TAG_VALUE" ]]; then
        echo "Found tag '$TAG_KEY' with value '$TAG_VALUE' on $found_count out of $subnet_count subnets"
    else
        echo "Found tag '$TAG_KEY' on $found_count out of $subnet_count subnets"
    fi
    echo
    
    if [[ $found_count -eq 0 ]]; then
        if [[ -n "$TAG_VALUE" ]]; then
            log_info "Tag '$TAG_KEY' with value '$TAG_VALUE' not found on any of the specified subnets. Nothing to delete."
        else
            log_info "Tag '$TAG_KEY' not found on any of the specified subnets. Nothing to delete."
        fi
        exit 0
    fi
    
    # Confirm action
    if [[ "$DRY_RUN" == "false" ]]; then
        if [[ -n "$TAG_VALUE" ]]; then
            echo "This will delete the tag '$TAG_KEY' with value '$TAG_VALUE' from $found_count subnet(s)."
        else
            echo "This will delete the tag '$TAG_KEY' from $found_count subnet(s)."
        fi
        read -p "Do you want to proceed? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Operation cancelled by user"
            exit 0
        fi
    fi
    
    # Process each subnet
    local success_count=0
    local error_count=0
    local skipped_count=0
    
    echo
    echo "=========================================="
    echo "DELETING TAGS"
    echo "=========================================="
    
    for subnet in $subnets_to_process; do
        if check_tag_exists "$subnet" "$TAG_KEY" "$TAG_VALUE"; then
            if delete_tag_from_subnet "$subnet" "$TAG_KEY" "$TAG_VALUE"; then
                ((success_count++))
            else
                ((error_count++))
            fi
        else
            ((skipped_count++))
        fi
    done
    
    # Summary
    echo
    echo "=========================================="
    echo "OPERATION SUMMARY"
    echo "=========================================="
    echo "Region: $REGION"
    echo "Tag key: $TAG_KEY"
    if [[ -n "$TAG_VALUE" ]]; then
        echo "Tag value filter: $TAG_VALUE"
    fi
    echo "Subnets processed: $subnet_count"
    echo "Successfully deleted: $success_count"
    echo "Skipped (tag not found or value mismatch): $skipped_count"
    echo "Errors: $error_count"
    echo "Dry run: $DRY_RUN"
    echo "=========================================="
    
    if [[ $error_count -gt 0 ]]; then
        exit 1
    fi
}

# Run main function
main
