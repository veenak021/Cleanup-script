#!/bin/bash

# Script to delete tags from AWS subnets
# Usage: ./delete_subnet_tags.sh [--region REGION] [--subnet-ids ID1,ID2] [--tag-keys KEY1,KEY2] [--kubernetes-cluster-tags] [--dry-run]

set -euo pipefail

# Default values
REGION=""
SUBNET_IDS=""
TAG_KEYS=""
DELETE_KUBERNETES_CLUSTER_TAGS=false
DRY_RUN=false
VERBOSE=false
CONFIRM=true

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
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
Usage: $0 [OPTIONS]

Delete tags from AWS subnets

OPTIONS:
    --region REGION              AWS region to operate in (default: current region)
    --subnet-ids IDS             Comma-separated list of subnet IDs to process
    --tag-keys KEYS              Comma-separated list of tag keys to delete
    --all-tags                   Delete all tags from specified subnets
    --kubernetes-cluster-tags     Delete only tags containing 'kubernetes.io/cluster/'
    --dry-run                    Show what would be deleted without actually deleting
    --no-confirm                 Skip confirmation prompt
    --verbose                    Enable verbose output
    -h, --help                   Show this help message

EXAMPLES:
    # Delete specific tags from specific subnets
    $0 --region us-west-2 --subnet-ids subnet-12345,subnet-67890 --tag-keys Environment,Project

    # Delete all tags from specific subnets
    $0 --region us-west-2 --subnet-ids subnet-12345 --all-tags

    # Delete only kubernetes.io/cluster/* tags from subnets
    $0 --region us-west-2 --subnet-ids subnet-12345 --kubernetes-cluster-tags

    # Dry run to see what would be deleted
    $0 --region us-west-2 --subnet-ids subnet-12345 --tag-keys Environment --dry-run

    # Delete kubernetes cluster tags from all subnets in region
    $0 --region us-west-2 --kubernetes-cluster-tags --no-confirm
EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --region)
            REGION="$2"
            shift 2
            ;;
        --subnet-ids)
            SUBNET_IDS="$2"
            shift 2
            ;;
        --tag-keys)
            TAG_KEYS="$2"
            shift 2
            ;;
        --all-tags)
            DELETE_ALL_TAGS=true
            shift
            ;;
        --kubernetes-cluster-tags)
            DELETE_KUBERNETES_CLUSTER_TAGS=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --no-confirm)
            CONFIRM=false
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

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
    log_error "AWS CLI is not installed. Please install it first."
    exit 1
fi

# Check if jq is installed for JSON processing
if ! command -v jq &> /dev/null; then
    log_error "jq is not installed. Please install it first."
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

# Validate required parameters
if [[ -z "$SUBNET_IDS" && -z "$TAG_KEYS" && "${DELETE_ALL_TAGS:-false}" == "false" && "${DELETE_KUBERNETES_CLUSTER_TAGS:-false}" == "false" ]]; then
    log_error "Either --subnet-ids, --tag-keys, --all-tags, or --kubernetes-cluster-tags must be specified"
    show_help
    exit 1
fi

if [[ -n "$TAG_KEYS" && "${DELETE_ALL_TAGS:-false}" == "true" ]]; then
    log_error "Cannot specify both --tag-keys and --all-tags"
    show_help
    exit 1
fi

if [[ -n "$TAG_KEYS" && "${DELETE_KUBERNETES_CLUSTER_TAGS:-false}" == "true" ]]; then
    log_error "Cannot specify both --tag-keys and --kubernetes-cluster-tags"
    show_help
    exit 1
fi

if [[ "${DELETE_ALL_TAGS:-false}" == "true" && "${DELETE_KUBERNETES_CLUSTER_TAGS:-false}" == "true" ]]; then
    log_error "Cannot specify both --all-tags and --kubernetes-cluster-tags"
    show_help
    exit 1
fi

log_info "Operating in region: $REGION"

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

# Function to get subnet details
get_subnet_details() {
    local subnet_id="$1"
    
    aws ec2 describe-subnets \
        --region "$REGION" \
        --subnet-ids "$subnet_id" \
        --query 'Subnets[0].[SubnetId,VpcId,AvailabilityZone,CidrBlock,Tags]' \
        --output json 2>/dev/null || echo "null"
}

# Function to get current tags for a subnet
get_subnet_tags() {
    local subnet_id="$1"
    
    local subnet_info=$(get_subnet_details "$subnet_id")
    if [[ "$subnet_info" == "null" ]]; then
        log_warn "Could not retrieve details for subnet: $subnet_id"
        return 1
    fi
    
    echo "$subnet_info" | jq -r '.[4] // []' 2>/dev/null || echo "[]"
}

# Function to delete specific tags from a subnet
delete_subnet_tags() {
    local subnet_id="$1"
    local tag_keys="$2"
    
    log_debug "Processing subnet: $subnet_id"
    
    # Get current tags
    local current_tags=$(get_subnet_tags "$subnet_id")
    if [[ "$current_tags" == "[]" ]]; then
        log_info "Subnet $subnet_id has no tags to delete"
        return 0
    fi
    
    # Convert comma-separated keys to array
    IFS=',' read -ra KEYS_ARRAY <<< "$tag_keys"
    
    # Build tag list for deletion
    local tags_to_delete=()
    for key in "${KEYS_ARRAY[@]}"; do
        # Check if tag exists
        local tag_exists=$(echo "$current_tags" | jq -r --arg key "$key" '.[] | select(.Key == $key) | .Key' 2>/dev/null || echo "")
        if [[ -n "$tag_exists" ]]; then
            tags_to_delete+=("Key=$key")
            log_debug "Tag '$key' found on subnet $subnet_id"
        else
            log_debug "Tag '$key' not found on subnet $subnet_id"
        fi
    done
    
    if [[ ${#tags_to_delete[@]} -eq 0 ]]; then
        log_info "No specified tags found on subnet $subnet_id"
        return 0
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "DRY RUN: Would delete tags from subnet $subnet_id: ${tags_to_delete[*]}"
        return 0
    fi
    
    # Delete tags
    log_info "Deleting tags from subnet $subnet_id: ${tags_to_delete[*]}"
    
    if aws ec2 delete-tags \
        --region "$REGION" \
        --resources "$subnet_id" \
        --tags "${tags_to_delete[@]}" 2>/dev/null; then
        log_info "Successfully deleted tags from subnet $subnet_id"
    else
        log_error "Failed to delete tags from subnet $subnet_id"
        return 1
    fi
}

# Function to delete all tags from a subnet
delete_all_subnet_tags() {
    local subnet_id="$1"
    
    log_debug "Processing subnet: $subnet_id"
    
    # Get current tags
    local current_tags=$(get_subnet_tags "$subnet_id")
    if [[ "$current_tags" == "[]" ]]; then
        log_info "Subnet $subnet_id has no tags to delete"
        return 0
    fi
    
    # Extract all tag keys
    local tag_keys=$(echo "$current_tags" | jq -r '.[].Key' 2>/dev/null || echo "")
    if [[ -z "$tag_keys" ]]; then
        log_info "No tags found on subnet $subnet_id"
        return 0
    fi
    
    # Convert to array (bash 3.2 compatible)
    local keys_array=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && keys_array+=("$line")
    done <<< "$tag_keys"
    
    # Build tag list for deletion
    local tags_to_delete=()
    for key in "${keys_array[@]}"; do
        [[ -n "$key" ]] && tags_to_delete+=("Key=$key")
    done
    
    if [[ ${#tags_to_delete[@]} -eq 0 ]]; then
        log_info "No tags found on subnet $subnet_id"
        return 0
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "DRY RUN: Would delete all tags from subnet $subnet_id: ${tags_to_delete[*]}"
        return 0
    fi
    
    # Delete all tags
    log_info "Deleting all tags from subnet $subnet_id: ${tags_to_delete[*]}"
    
    if aws ec2 delete-tags \
        --region "$REGION" \
        --resources "$subnet_id" \
        --tags "${tags_to_delete[@]}" 2>/dev/null; then
        log_info "Successfully deleted all tags from subnet $subnet_id"
    else
        log_error "Failed to delete tags from subnet $subnet_id"
        return 1
    fi
}

# Function to delete kubernetes.io/cluster/* tags from a subnet
delete_kubernetes_cluster_tags() {
    local subnet_id="$1"
    
    log_debug "Processing subnet: $subnet_id"
    
    # Get current tags
    local current_tags=$(get_subnet_tags "$subnet_id")
    if [[ "$current_tags" == "[]" ]]; then
        log_info "Subnet $subnet_id has no tags to delete"
        return 0
    fi
    
    # Filter tags that contain 'kubernetes.io/cluster/'
    local matching_tags=$(echo "$current_tags" | jq -r '.[] | select(.Key | contains("kubernetes.io/cluster/")) | .Key' 2>/dev/null || echo "")
    
    if [[ -z "$matching_tags" ]]; then
        log_info "No kubernetes.io/cluster/* tags found on subnet $subnet_id"
        return 0
    fi
    
    # Convert to array (bash 3.2 compatible)
    local keys_array=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && keys_array+=("$line")
    done <<< "$matching_tags"
    
    # Build tag list for deletion
    local tags_to_delete=()
    for key in "${keys_array[@]}"; do
        if [[ -n "$key" ]]; then
            tags_to_delete+=("Key=$key")
            log_debug "Found kubernetes cluster tag: $key"
        fi
    done
    
    if [[ ${#tags_to_delete[@]} -eq 0 ]]; then
        log_info "No kubernetes.io/cluster/* tags found on subnet $subnet_id"
        return 0
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "DRY RUN: Would delete kubernetes.io/cluster/* tags from subnet $subnet_id: ${tags_to_delete[*]}"
        return 0
    fi
    
    # Delete kubernetes cluster tags
    log_info "Deleting kubernetes.io/cluster/* tags from subnet $subnet_id: ${tags_to_delete[*]}"
    
    if aws ec2 delete-tags \
        --region "$REGION" \
        --resources "$subnet_id" \
        --tags "${tags_to_delete[@]}" 2>/dev/null; then
        log_info "Successfully deleted kubernetes.io/cluster/* tags from subnet $subnet_id"
    else
        log_error "Failed to delete tags from subnet $subnet_id"
        return 1
    fi
}

# Function to display subnet information
display_subnet_info() {
    local subnet_id="$1"
    
    local subnet_info=$(get_subnet_details "$subnet_id")
    if [[ "$subnet_info" == "null" ]]; then
        log_warn "Could not retrieve details for subnet: $subnet_id"
        return 1
    fi
    
    local vpc_id=$(echo "$subnet_info" | jq -r '.[1]')
    local az=$(echo "$subnet_info" | jq -r '.[2]')
    local cidr=$(echo "$subnet_info" | jq -r '.[3]')
    local tags=$(echo "$subnet_info" | jq -r '.[4] // []')
    
    echo "  Subnet ID: $subnet_id"
    echo "  VPC ID: $vpc_id"
    echo "  AZ: $az"
    echo "  CIDR: $cidr"
    echo "  Current Tags:"
    if [[ "$tags" != "[]" ]]; then
        echo "$tags" | jq -r '.[] | "    \(.Key): \(.Value)"' 2>/dev/null || echo "    (Unable to parse tags)"
    else
        echo "    (No tags)"
    fi
    echo
}

# Function to confirm action
confirm_action() {
    if [[ "$CONFIRM" == "false" ]]; then
        return 0
    fi
    
    echo
    echo "=========================================="
    echo "CONFIRMATION REQUIRED"
    echo "=========================================="
    echo "Region: $REGION"
    echo "Subnets: ${SUBNET_IDS:-"All subnets in region"}"
    if [[ "${DELETE_ALL_TAGS:-false}" == "true" ]]; then
        echo "Action: Delete ALL tags"
    elif [[ "${DELETE_KUBERNETES_CLUSTER_TAGS:-false}" == "true" ]]; then
        echo "Action: Delete tags containing 'kubernetes.io/cluster/'"
    else
        echo "Action: Delete tags: $TAG_KEYS"
    fi
    echo "Dry Run: $DRY_RUN"
    echo "=========================================="
    echo
    
    read -p "Do you want to proceed? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Operation cancelled by user"
        exit 0
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
    
    # Display subnet information
    if [[ "$VERBOSE" == "true" ]]; then
        echo
        echo "=========================================="
        echo "SUBNET INFORMATION"
        echo "=========================================="
        for subnet in $subnets_to_process; do
            display_subnet_info "$subnet"
        done
    fi
    
    # Confirm action
    confirm_action
    
    # Process each subnet
    local success_count=0
    local error_count=0
    
    for subnet in $subnets_to_process; do
        if [[ "${DELETE_ALL_TAGS:-false}" == "true" ]]; then
            if delete_all_subnet_tags "$subnet"; then
                ((success_count++))
            else
                ((error_count++))
            fi
        elif [[ "${DELETE_KUBERNETES_CLUSTER_TAGS:-false}" == "true" ]]; then
            if delete_kubernetes_cluster_tags "$subnet"; then
                ((success_count++))
            else
                ((error_count++))
            fi
        else
            if delete_subnet_tags "$subnet" "$TAG_KEYS"; then
                ((success_count++))
            else
                ((error_count++))
            fi
        fi
    done
    
    # Summary
    echo
    echo "=========================================="
    echo "OPERATION SUMMARY"
    echo "=========================================="
    echo "Region: $REGION"
    echo "Subnets processed: $subnet_count"
    echo "Successful: $success_count"
    echo "Errors: $error_count"
    echo "Dry run: $DRY_RUN"
    echo "=========================================="
    
    if [[ $error_count -gt 0 ]]; then
        exit 1
    fi
}

# Run main function
main
