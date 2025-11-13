#!/bin/bash

# Quick script to delete tags from subnets (supports exact match or contains pattern)
# Usage: ./quick_delete_subnet_tag.sh TAG_KEY [TAG_VALUE] [SUBNET_ID1,SUBNET_ID2,...] [REGION]
#        ./quick_delete_subnet_tag.sh --contains PATTERN [SUBNET_ID1,SUBNET_ID2,...] [REGION]
#        ./quick_delete_subnet_tag.sh --dry-run [other options...]
#        ./quick_delete_subnet_tag.sh --parallel [other options...]

set -euo pipefail

# Get parameters
TAG_KEY="${1:-}"
TAG_VALUE="${2:-}"
SUBNET_IDS="${3:-}"
REGION="${4:-$(aws configure get region 2>/dev/null || echo 'us-west-2')}"
CONTAINS_PATTERN=""
DRY_RUN=false
PARALLEL=false
MAX_PARALLEL=10

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Help function
show_help() {
    cat << EOF
Quick delete tags from subnets (supports exact match or contains pattern)

Usage: 
    $0 TAG_KEY [TAG_VALUE] [SUBNET_IDS] [REGION]
    $0 --contains PATTERN [SUBNET_IDS] [REGION]
    $0 --dry-run [other options...]
    $0 --parallel [other options...]

Arguments:
    TAG_KEY      Tag key to delete (required for exact match mode)
    TAG_VALUE    Tag value to match (optional, only delete if value matches)
    --contains   Delete all tags that contain this pattern in the key
    --dry-run    Show what would be deleted without actually deleting
    --parallel   Process subnets in parallel (faster for multiple subnets)
    SUBNET_IDS   Comma-separated subnet IDs (optional, defaults to all subnets)
    REGION       AWS region (optional, defaults to configured region)

Examples:
    # Delete exact tag key
    $0 Environment
    $0 Environment dev
    
    # Delete all tags containing pattern
    $0 --contains kubernetes.io/cluster/
    $0 --contains kubernetes.io/cluster/ subnet-12345,subnet-67890
    
    # Dry run to see what would be deleted
    $0 --dry-run --contains kubernetes.io/cluster/
    $0 --dry-run Environment dev subnet-12345
    
    # Parallel processing for faster execution
    $0 --parallel --contains kubernetes.io/cluster/
    $0 --parallel --dry-run --contains kubernetes.io/cluster/
EOF
}

# Parse arguments
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
    shift
    # Re-parse remaining arguments
    if [[ "${1:-}" == "--parallel" ]]; then
        PARALLEL=true
        shift
    fi
    if [[ "${1:-}" == "--contains" ]]; then
        CONTAINS_PATTERN="${2:-}"
        SUBNET_IDS="${3:-}"
        REGION="${4:-$(aws configure get region 2>/dev/null || echo 'us-west-2')}"
        TAG_KEY=""
        TAG_VALUE=""
        
        if [[ -z "$CONTAINS_PATTERN" ]]; then
            echo -e "${RED}Error: Pattern is required with --contains${NC}"
            show_help
            exit 1
        fi
    else
        TAG_KEY="${1:-}"
        TAG_VALUE="${2:-}"
        SUBNET_IDS="${3:-}"
        REGION="${4:-$(aws configure get region 2>/dev/null || echo 'us-west-2')}"
        
        if [[ -z "$TAG_KEY" ]]; then
            echo -e "${RED}Error: Tag key is required${NC}"
            show_help
            exit 1
        fi
    fi
elif [[ "${1:-}" == "--parallel" ]]; then
    PARALLEL=true
    shift
    # Re-parse remaining arguments
    if [[ "${1:-}" == "--dry-run" ]]; then
        DRY_RUN=true
        shift
    fi
    if [[ "${1:-}" == "--contains" ]]; then
        CONTAINS_PATTERN="${2:-}"
        SUBNET_IDS="${3:-}"
        REGION="${4:-$(aws configure get region 2>/dev/null || echo 'us-west-2')}"
        TAG_KEY=""
        TAG_VALUE=""
        
        if [[ -z "$CONTAINS_PATTERN" ]]; then
            echo -e "${RED}Error: Pattern is required with --contains${NC}"
            show_help
            exit 1
        fi
    else
        TAG_KEY="${1:-}"
        TAG_VALUE="${2:-}"
        SUBNET_IDS="${3:-}"
        REGION="${4:-$(aws configure get region 2>/dev/null || echo 'us-west-2')}"
        
        if [[ -z "$TAG_KEY" ]]; then
            echo -e "${RED}Error: Tag key is required${NC}"
            show_help
            exit 1
        fi
    fi
elif [[ "${1:-}" == "--contains" ]]; then
    CONTAINS_PATTERN="${2:-}"
    SUBNET_IDS="${3:-}"
    REGION="${4:-$(aws configure get region 2>/dev/null || echo 'us-west-2')}"
    TAG_KEY=""
    TAG_VALUE=""
    
    if [[ -z "$CONTAINS_PATTERN" ]]; then
        echo -e "${RED}Error: Pattern is required with --contains${NC}"
        show_help
        exit 1
    fi
else
    # Check if tag key provided for exact match mode
    if [[ -z "$TAG_KEY" ]]; then
        echo -e "${RED}Error: Tag key is required${NC}"
        show_help
        exit 1
    fi
fi

# Check AWS CLI
if ! command -v aws &> /dev/null; then
    echo -e "${RED}Error: AWS CLI not found${NC}"
    exit 1
fi

# Check AWS credentials
if ! aws sts get-caller-identity &> /dev/null; then
    echo -e "${RED}Error: AWS credentials not configured${NC}"
    exit 1
fi

if [[ "$DRY_RUN" == "true" ]]; then
    if [[ -n "$CONTAINS_PATTERN" ]]; then
        echo -e "${YELLOW}DRY RUN: Would delete all tags containing '$CONTAINS_PATTERN' from subnets in region '$REGION'${NC}"
    elif [[ -n "$TAG_VALUE" ]]; then
        echo -e "${YELLOW}DRY RUN: Would delete tag '$TAG_KEY' with value '$TAG_VALUE' from subnets in region '$REGION'${NC}"
    else
        echo -e "${YELLOW}DRY RUN: Would delete tag '$TAG_KEY' from subnets in region '$REGION'${NC}"
    fi
elif [[ -n "$CONTAINS_PATTERN" ]]; then
    echo -e "${GREEN}Deleting all tags containing '$CONTAINS_PATTERN' from subnets in region '$REGION'${NC}"
elif [[ -n "$TAG_VALUE" ]]; then
    echo -e "${GREEN}Deleting tag '$TAG_KEY' with value '$TAG_VALUE' from subnets in region '$REGION'${NC}"
else
    echo -e "${GREEN}Deleting tag '$TAG_KEY' from subnets in region '$REGION'${NC}"
fi

if [[ "$PARALLEL" == "true" ]]; then
    echo -e "${BLUE}Parallel processing enabled (max $MAX_PARALLEL concurrent operations)${NC}"
fi

# Get subnets to process
if [[ -n "$SUBNET_IDS" ]]; then
    # Use provided subnet IDs
    SUBNETS=$(echo "$SUBNET_IDS" | tr ',' ' ')
else
    # Get all subnets
    SUBNETS=$(aws ec2 describe-subnets --region "$REGION" --query 'Subnets[].SubnetId' --output text 2>/dev/null)
fi

if [[ -z "$SUBNETS" ]]; then
    echo -e "${YELLOW}No subnets found${NC}"
    exit 0
fi

# Function to process a single subnet
process_subnet() {
    local subnet="$1"
    local result_file="$2"
    
    local success=0
    local error=0
    
    if [[ -n "$CONTAINS_PATTERN" ]]; then
        # Contains mode - find and delete all tags containing the pattern
        TAGS_TO_DELETE=$(aws ec2 describe-tags \
            --region "$REGION" \
            --filters "Name=resource-id,Values=$subnet" \
            --query "Tags[?contains(Key, '$CONTAINS_PATTERN')].[Key,Value]" \
            --output text 2>/dev/null || echo "")
        
        if [[ -n "$TAGS_TO_DELETE" ]]; then
            # Parse the tags and delete them
            while IFS=$'\t' read -r tag_key tag_value; do
                if [[ -n "$tag_key" ]]; then
                    if [[ "$DRY_RUN" == "true" ]]; then
                        echo "DRY RUN: Would delete $subnet: $tag_key = '$tag_value'" >> "$result_file"
                        ((success++))
                    else
                        if aws ec2 delete-tags \
                            --region "$REGION" \
                            --resources "$subnet" \
                            --tags "Key=$tag_key" &>/dev/null; then
                            echo "✓ $subnet: $tag_key = '$tag_value' (deleted)" >> "$result_file"
                            ((success++))
                        else
                            echo "✗ $subnet: Failed to delete $tag_key" >> "$result_file"
                            ((error++))
                        fi
                    fi
                fi
            done <<< "$TAGS_TO_DELETE"
        else
            echo "- $subnet: No tags containing '$CONTAINS_PATTERN' found" >> "$result_file"
        fi
    else
        # Exact match mode - original logic
        # Get tag value
        VALUE=$(aws ec2 describe-tags \
            --region "$REGION" \
            --filters "Name=resource-id,Values=$subnet" "Name=key,Values=$TAG_KEY" \
            --query 'Tags[0].Value' \
            --output text 2>/dev/null || echo "")
        
        # Check if tag exists and value matches (if specified)
        if [[ -n "$VALUE" && "$VALUE" != "None" ]]; then
            # Tag exists, check value filter
            if [[ -z "$TAG_VALUE" || "$VALUE" == "$TAG_VALUE" ]]; then
                # Delete the tag
                if [[ "$DRY_RUN" == "true" ]]; then
                    if [[ -n "$TAG_VALUE" ]]; then
                        echo "DRY RUN: Would delete $subnet: $TAG_KEY = '$VALUE' (matches '$TAG_VALUE')" >> "$result_file"
                    else
                        echo "DRY RUN: Would delete $subnet: $TAG_KEY = '$VALUE'" >> "$result_file"
                    fi
                    ((success++))
                else
                    if aws ec2 delete-tags \
                        --region "$REGION" \
                        --resources "$subnet" \
                        --tags "Key=$TAG_KEY" &>/dev/null; then
                        if [[ -n "$TAG_VALUE" ]]; then
                            echo "✓ $subnet: $TAG_KEY = '$VALUE' (matches '$TAG_VALUE', deleted)" >> "$result_file"
                        else
                            echo "✓ $subnet: $TAG_KEY = '$VALUE' (deleted)" >> "$result_file"
                        fi
                        ((success++))
                    else
                        echo "✗ $subnet: Failed to delete $TAG_KEY" >> "$result_file"
                        ((error++))
                    fi
                fi
            else
                echo "- $subnet: $TAG_KEY = '$VALUE' (doesn't match '$TAG_VALUE')" >> "$result_file"
            fi
        else
            echo "- $subnet: $TAG_KEY (not found)" >> "$result_file"
        fi
    fi
    
    # Write results to file
    echo "SUCCESS:$success" >> "$result_file"
    echo "ERROR:$error" >> "$result_file"
}

# Process subnets
SUCCESS=0
TOTAL=0
ERROR=0

if [[ "$PARALLEL" == "true" ]]; then
    # Parallel processing
    local subnet_count=$(echo "$SUBNETS" | wc -w)
    echo -e "${BLUE}Starting parallel processing of $subnet_count subnets...${NC}"
    
    # Create temporary directory for results
    TEMP_DIR=$(mktemp -d)
    trap "rm -rf $TEMP_DIR" EXIT
    
    # Process subnets in parallel
    local pids=()
    local result_files=()
    
    for subnet in $SUBNETS; do
        ((TOTAL++))
        result_file="$TEMP_DIR/result_$subnet.txt"
        result_files+=("$result_file")
        
        # Start background process
        process_subnet "$subnet" "$result_file" &
        pids+=($!)
        
        # Limit concurrent processes
        if [[ ${#pids[@]} -ge $MAX_PARALLEL ]]; then
            # Wait for one process to complete
            wait "${pids[0]}"
            pids=("${pids[@]:1}")  # Remove first element
        fi
    done
    
    # Wait for all remaining processes
    for pid in "${pids[@]}"; do
        wait "$pid"
    done
    
    # Collect and display results
    for result_file in "${result_files[@]}"; do
        if [[ -f "$result_file" ]]; then
            # Display output lines (skip SUCCESS/ERROR lines)
            while IFS= read -r line; do
                if [[ "$line" =~ ^(SUCCESS|ERROR): ]]; then
                    # Parse success/error counts
                    if [[ "$line" =~ ^SUCCESS:([0-9]+)$ ]]; then
                        SUCCESS=$((SUCCESS + BASH_REMATCH[1]))
                    elif [[ "$line" =~ ^ERROR:([0-9]+)$ ]]; then
                        ERROR=$((ERROR + BASH_REMATCH[1]))
                    fi
                else
                    # Display the line with appropriate colors
                    if [[ "$line" =~ ^✓ ]]; then
                        echo -e "${GREEN}$line${NC}"
                    elif [[ "$line" =~ ^✗ ]]; then
                        echo -e "${RED}$line${NC}"
                    elif [[ "$line" =~ ^DRY\ RUN ]]; then
                        echo -e "${YELLOW}$line${NC}"
                    else
                        echo -e "${YELLOW}$line${NC}"
                    fi
                fi
            done < "$result_file"
        fi
    done
else
    # Sequential processing (original logic)
    for subnet in $SUBNETS; do
        ((TOTAL++))
        
        if [[ -n "$CONTAINS_PATTERN" ]]; then
            # Contains mode - find and delete all tags containing the pattern
            TAGS_TO_DELETE=$(aws ec2 describe-tags \
                --region "$REGION" \
                --filters "Name=resource-id,Values=$subnet" \
                --query "Tags[?contains(Key, '$CONTAINS_PATTERN')].[Key,Value]" \
                --output text 2>/dev/null || echo "")
            
            if [[ -n "$TAGS_TO_DELETE" ]]; then
                # Parse the tags and delete them
                while IFS=$'\t' read -r tag_key tag_value; do
                    if [[ -n "$tag_key" ]]; then
                        if [[ "$DRY_RUN" == "true" ]]; then
                            echo -e "${YELLOW}DRY RUN: Would delete${NC} $subnet: $tag_key = '$tag_value'"
                            ((SUCCESS++))
                        else
                            if aws ec2 delete-tags \
                                --region "$REGION" \
                                --resources "$subnet" \
                                --tags "Key=$tag_key" &>/dev/null; then
                                echo -e "${GREEN}✓${NC} $subnet: $tag_key = '$tag_value' (deleted)"
                                ((SUCCESS++))
                            else
                                echo -e "${RED}✗${NC} $subnet: Failed to delete $tag_key"
                                ((ERROR++))
                            fi
                        fi
                    fi
                done <<< "$TAGS_TO_DELETE"
            else
                echo -e "${YELLOW}-${NC} $subnet: No tags containing '$CONTAINS_PATTERN' found"
            fi
        else
            # Exact match mode - original logic
            # Get tag value
            VALUE=$(aws ec2 describe-tags \
                --region "$REGION" \
                --filters "Name=resource-id,Values=$subnet" "Name=key,Values=$TAG_KEY" \
                --query 'Tags[0].Value' \
                --output text 2>/dev/null || echo "")
            
            # Check if tag exists and value matches (if specified)
            if [[ -n "$VALUE" && "$VALUE" != "None" ]]; then
                # Tag exists, check value filter
                if [[ -z "$TAG_VALUE" || "$VALUE" == "$TAG_VALUE" ]]; then
                    # Delete the tag
                    if [[ "$DRY_RUN" == "true" ]]; then
                        if [[ -n "$TAG_VALUE" ]]; then
                            echo -e "${YELLOW}DRY RUN: Would delete${NC} $subnet: $TAG_KEY = '$VALUE' (matches '$TAG_VALUE')"
                        else
                            echo -e "${YELLOW}DRY RUN: Would delete${NC} $subnet: $TAG_KEY = '$VALUE'"
                        fi
                        ((SUCCESS++))
                    else
                        if aws ec2 delete-tags \
                            --region "$REGION" \
                            --resources "$subnet" \
                            --tags "Key=$TAG_KEY" &>/dev/null; then
                            if [[ -n "$TAG_VALUE" ]]; then
                                echo -e "${GREEN}✓${NC} $subnet: $TAG_KEY = '$VALUE' (matches '$TAG_VALUE', deleted)"
                            else
                                echo -e "${GREEN}✓${NC} $subnet: $TAG_KEY = '$VALUE' (deleted)"
                            fi
                            ((SUCCESS++))
                        else
                            echo -e "${RED}✗${NC} $subnet: Failed to delete $TAG_KEY"
                            ((ERROR++))
                        fi
                    fi
                else
                    echo -e "${YELLOW}-${NC} $subnet: $TAG_KEY = '$VALUE' (doesn't match '$TAG_VALUE')"
                fi
            else
                echo -e "${YELLOW}-${NC} $subnet: $TAG_KEY (not found)"
            fi
        fi
    done
fi

echo
if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${YELLOW}Summary: Would delete from $SUCCESS out of $TOTAL subnets (DRY RUN)${NC}"
else
    echo -e "${GREEN}Summary: Deleted from $SUCCESS out of $TOTAL subnets${NC}"
fi

if [[ $ERROR -gt 0 ]]; then
    echo -e "${RED}Errors: $ERROR${NC}"
fi

if [[ "$PARALLEL" == "true" ]]; then
    echo -e "${BLUE}Parallel processing completed${NC}"
fi
