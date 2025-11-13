#!/bin/bash

# Script to list AWS instances (EC2, EKS, RDS) running for more than 2 days
# Usage: ./list_old_aws_instances.sh [--days N] [--region REGION] [--output FORMAT]

set -euo pipefail

# Default values
DAYS_AGO=2
REGION=""
OUTPUT_FORMAT="table"
INCLUDE_EC2=true
INCLUDE_EKS=true
INCLUDE_RDS=true
VERBOSE=false

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

List AWS instances (EC2, EKS, RDS) running for more than specified days

OPTIONS:
    --days N            Number of days to look back for instances (default: 2)
    --region REGION     AWS region to operate in (default: current region)
    --output FORMAT     Output format: table, json, csv (default: table)
    --no-ec2           Skip EC2 instances
    --no-eks           Skip EKS clusters
    --no-rds           Skip RDS instances
    --verbose          Enable verbose output
    -h, --help         Show this help message

EXAMPLES:
    $0 --days 3 --region us-west-2
    $0 --output json --verbose
    $0 --no-rds --days 1
EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --days)
            DAYS_AGO="$2"
            shift 2
            ;;
        --region)
            REGION="$2"
            shift 2
            ;;
        --output)
            OUTPUT_FORMAT="$2"
            shift 2
            ;;
        --no-ec2)
            INCLUDE_EC2=false
            shift
            ;;
        --no-eks)
            INCLUDE_EKS=false
            shift
            ;;
        --no-rds)
            INCLUDE_RDS=false
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

log_info "Operating in region: $REGION"
log_info "Looking for instances older than $DAYS_AGO days"

# Calculate the cutoff date
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS
    CUTOFF_DATE=$(date -v-${DAYS_AGO}d +%Y-%m-%d)
    CUTOFF_DATETIME=$(date -v-${DAYS_AGO}d +%Y-%m-%dT%H:%M:%S)
else
    # Linux
    CUTOFF_DATE=$(date -d "${DAYS_AGO} days ago" +%Y-%m-%d)
    CUTOFF_DATETIME=$(date -d "${DAYS_AGO} days ago" +%Y-%m-%dT%H:%M:%S)
fi

log_info "Cutoff date: $CUTOFF_DATE"

# Arrays to store instance information
declare -a EC2_INSTANCES=()
declare -a EKS_CLUSTERS=()
declare -a RDS_INSTANCES=()

# Function to check if a date is older than cutoff
is_older_than_cutoff() {
    local instance_date="$1"
    local cutoff="$2"
    
    if [[ "$instance_date" < "$cutoff" ]]; then
        return 0
    else
        return 1
    fi
}

# Function to get instance age in days
get_instance_age() {
    local instance_date="$1"
    local current_date=$(date +%Y-%m-%d)
    
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        local days_diff=$(( ($(date -j -f "%Y-%m-%d" "$current_date" +%s) - $(date -j -f "%Y-%m-%d" "$instance_date" +%s)) / 86400 ))
    else
        # Linux
        local days_diff=$(( ($(date -d "$current_date" +%s) - $(date -d "$instance_date" +%s)) / 86400 ))
    fi
    
    echo "$days_diff"
}

# Function to list EC2 instances
list_ec2_instances() {
    if [[ "$INCLUDE_EC2" == "false" ]]; then
        return
    fi
    
    log_info "Fetching EC2 instances..."
    
    # Get all EC2 instances
    local instances=$(aws ec2 describe-instances \
        --region "$REGION" \
        --query 'Reservations[].Instances[].[InstanceId,State.Name,LaunchTime,Tags[?Key==`Name`].Value|[0],InstanceType]' \
        --output text 2>/dev/null || true)
    
    if [[ -z "$instances" ]]; then
        log_info "No EC2 instances found in region $REGION"
        return
    fi
    
    while IFS=$'\t' read -r instance_id state launch_time name instance_type; do
        # Skip terminated instances
        if [[ "$state" != "running" ]]; then
            continue
        fi
        
        # Extract date from launch time
        local created_date=$(echo "$launch_time" | cut -d'T' -f1)
        
        if is_older_than_cutoff "$created_date" "$CUTOFF_DATE"; then
            local age_days=$(get_instance_age "$created_date")
            local name_display="${name:-N/A}"
            EC2_INSTANCES+=("$instance_id|$name_display|$instance_type|$created_date|$age_days")
            log_debug "EC2 instance $instance_id ($name_display) created on $created_date - $age_days days old"
        fi
    done <<< "$instances"
}

# Function to list EKS clusters
list_eks_clusters() {
    if [[ "$INCLUDE_EKS" == "false" ]]; then
        return
    fi
    
    log_info "Fetching EKS clusters..."
    
    # Get all EKS clusters
    local clusters=$(aws eks list-clusters --region "$REGION" --output text --query 'clusters[]' 2>/dev/null || true)
    
    if [[ -z "$clusters" ]]; then
        log_info "No EKS clusters found in region $REGION"
        return
    fi
    
    for cluster in $clusters; do
        log_debug "Checking EKS cluster: $cluster"
        
        # Get cluster details
        local cluster_info=$(aws eks describe-cluster --region "$REGION" --name "$cluster" --output json 2>/dev/null || true)
        
        if [[ -z "$cluster_info" ]]; then
            log_warn "Could not get details for EKS cluster: $cluster"
            continue
        fi
        
        # Extract creation date and status
        local created_at=$(echo "$cluster_info" | jq -r '.cluster.createdAt' 2>/dev/null || echo "")
        local status=$(echo "$cluster_info" | jq -r '.cluster.status' 2>/dev/null || echo "")
        local version=$(echo "$cluster_info" | jq -r '.cluster.version' 2>/dev/null || echo "")
        
        if [[ -z "$created_at" ]]; then
            log_warn "Could not extract creation date for EKS cluster: $cluster"
            continue
        fi
        
        # Skip if not active
        if [[ "$status" != "ACTIVE" ]]; then
            continue
        fi
        
        # Extract date from creation time
        local created_date=$(echo "$created_at" | cut -d'T' -f1)
        
        if is_older_than_cutoff "$created_date" "$CUTOFF_DATE"; then
            local age_days=$(get_instance_age "$created_date")
            EKS_CLUSTERS+=("$cluster|$version|$created_date|$age_days")
            log_debug "EKS cluster $cluster created on $created_date - $age_days days old"
        fi
    done
}

# Function to list RDS instances
list_rds_instances() {
    if [[ "$INCLUDE_RDS" == "false" ]]; then
        return
    fi
    
    log_info "Fetching RDS instances..."
    
    # Get all RDS instances
    local instances=$(aws rds describe-db-instances \
        --region "$REGION" \
        --query 'DBInstances[].[DBInstanceIdentifier,DBInstanceStatus,InstanceCreateTime,DBInstanceClass,Engine]' \
        --output text 2>/dev/null || true)
    
    if [[ -z "$instances" ]]; then
        log_info "No RDS instances found in region $REGION"
        return
    fi
    
    while IFS=$'\t' read -r instance_id status create_time instance_class engine; do
        # Skip stopped instances
        if [[ "$status" == "stopped" ]]; then
            continue
        fi
        
        # Extract date from creation time
        local created_date=$(echo "$create_time" | cut -d'T' -f1)
        
        if is_older_than_cutoff "$created_date" "$CUTOFF_DATE"; then
            local age_days=$(get_instance_age "$created_date")
            RDS_INSTANCES+=("$instance_id|$instance_class|$engine|$created_date|$age_days")
            log_debug "RDS instance $instance_id created on $created_date - $age_days days old"
        fi
    done <<< "$instances"
}

# Function to output results in table format
output_table() {
    local total_count=$((${#EC2_INSTANCES[@]} + ${#EKS_CLUSTERS[@]} + ${#RDS_INSTANCES[@]}))
    
    echo
    echo "=========================================="
    echo "AWS Instances Running for More Than $DAYS_AGO Days"
    echo "=========================================="
    echo "Region: $REGION"
    echo "Cutoff Date: $CUTOFF_DATE"
    echo "Total Instances: $total_count"
    echo "=========================================="
    
    if [[ ${#EC2_INSTANCES[@]} -gt 0 ]]; then
        echo
        echo "EC2 Instances (${#EC2_INSTANCES[@]}):"
        echo "----------------------------------------"
        printf "%-20s %-30s %-15s %-12s %-8s\n" "Instance ID" "Name" "Type" "Created" "Age (days)"
        echo "----------------------------------------"
        for instance in "${EC2_INSTANCES[@]}"; do
            IFS='|' read -r instance_id name instance_type created_date age_days <<< "$instance"
            printf "%-20s %-30s %-15s %-12s %-8s\n" "$instance_id" "$name" "$instance_type" "$created_date" "$age_days"
        done
    fi
    
    if [[ ${#EKS_CLUSTERS[@]} -gt 0 ]]; then
        echo
        echo "EKS Clusters (${#EKS_CLUSTERS[@]}):"
        echo "----------------------------------------"
        printf "%-30s %-10s %-12s %-8s\n" "Cluster Name" "Version" "Created" "Age (days)"
        echo "----------------------------------------"
        for cluster in "${EKS_CLUSTERS[@]}"; do
            IFS='|' read -r cluster_name version created_date age_days <<< "$cluster"
            printf "%-30s %-10s %-12s %-8s\n" "$cluster_name" "$version" "$created_date" "$age_days"
        done
    fi
    
    if [[ ${#RDS_INSTANCES[@]} -gt 0 ]]; then
        echo
        echo "RDS Instances (${#RDS_INSTANCES[@]}):"
        echo "----------------------------------------"
        printf "%-30s %-15s %-15s %-12s %-8s\n" "Instance ID" "Class" "Engine" "Created" "Age (days)"
        echo "----------------------------------------"
        for instance in "${RDS_INSTANCES[@]}"; do
            IFS='|' read -r instance_id instance_class engine created_date age_days <<< "$instance"
            printf "%-30s %-15s %-15s %-12s %-8s\n" "$instance_id" "$instance_class" "$engine" "$created_date" "$age_days"
        done
    fi
    
    if [[ $total_count -eq 0 ]]; then
        echo
        echo "No instances found running for more than $DAYS_AGO days."
    fi
}

# Function to output results in JSON format
output_json() {
    local json_output="{"
    json_output+="\"region\":\"$REGION\","
    json_output+="\"cutoff_date\":\"$CUTOFF_DATE\","
    json_output+="\"days_ago\":$DAYS_AGO,"
    json_output+="\"ec2_instances\":["
    
    # EC2 instances
    for i in "${!EC2_INSTANCES[@]}"; do
        if [[ $i -gt 0 ]]; then
            json_output+=","
        fi
        IFS='|' read -r instance_id name instance_type created_date age_days <<< "${EC2_INSTANCES[$i]}"
        json_output+="{\"instance_id\":\"$instance_id\",\"name\":\"$name\",\"type\":\"$instance_type\",\"created_date\":\"$created_date\",\"age_days\":$age_days}"
    done
    
    json_output+="],\"eks_clusters\":["
    
    # EKS clusters
    for i in "${!EKS_CLUSTERS[@]}"; do
        if [[ $i -gt 0 ]]; then
            json_output+=","
        fi
        IFS='|' read -r cluster_name version created_date age_days <<< "${EKS_CLUSTERS[$i]}"
        json_output+="{\"cluster_name\":\"$cluster_name\",\"version\":\"$version\",\"created_date\":\"$created_date\",\"age_days\":$age_days}"
    done
    
    json_output+="],\"rds_instances\":["
    
    # RDS instances
    for i in "${!RDS_INSTANCES[@]}"; do
        if [[ $i -gt 0 ]]; then
            json_output+=","
        fi
        IFS='|' read -r instance_id instance_class engine created_date age_days <<< "${RDS_INSTANCES[$i]}"
        json_output+="{\"instance_id\":\"$instance_id\",\"class\":\"$instance_class\",\"engine\":\"$engine\",\"created_date\":\"$created_date\",\"age_days\":$age_days}"
    done
    
    json_output+="],\"summary\":{"
    json_output+="\"total_ec2\":${#EC2_INSTANCES[@]},"
    json_output+="\"total_eks\":${#EKS_CLUSTERS[@]},"
    json_output+="\"total_rds\":${#RDS_INSTANCES[@]},"
    json_output+="\"total_instances\":$((${#EC2_INSTANCES[@]} + ${#EKS_CLUSTERS[@]} + ${#RDS_INSTANCES[@]}))"
    json_output+="}}"
    
    echo "$json_output" | jq .
}

# Function to output results in CSV format
output_csv() {
    echo "Service,Instance_ID,Name/Cluster,Type/Version/Engine,Created_Date,Age_Days"
    
    # EC2 instances
    for instance in "${EC2_INSTANCES[@]}"; do
        IFS='|' read -r instance_id name instance_type created_date age_days <<< "$instance"
        echo "EC2,$instance_id,\"$name\",$instance_type,$created_date,$age_days"
    done
    
    # EKS clusters
    for cluster in "${EKS_CLUSTERS[@]}"; do
        IFS='|' read -r cluster_name version created_date age_days <<< "$cluster"
        echo "EKS,$cluster_name,$cluster_name,$version,$created_date,$age_days"
    done
    
    # RDS instances
    for instance in "${RDS_INSTANCES[@]}"; do
        IFS='|' read -r instance_id instance_class engine created_date age_days <<< "$instance"
        echo "RDS,$instance_id,$instance_id,\"$instance_class/$engine\",$created_date,$age_days"
    done
}

# Main execution
main() {
    # List instances
    list_ec2_instances
    list_eks_clusters
    list_rds_instances
    
    # Output results
    case "$OUTPUT_FORMAT" in
        "table")
            output_table
            ;;
        "json")
            output_json
            ;;
        "csv")
            output_csv
            ;;
        *)
            log_error "Invalid output format: $OUTPUT_FORMAT"
            exit 1
            ;;
    esac
}

# Run main function
main
