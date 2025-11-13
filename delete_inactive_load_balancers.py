#!/usr/bin/env python3
"""
Script to delete inactive load balancers from AWS account that are older than specified days.

A load balancer is considered inactive if:
- ELBv2 (ALB/NLB): Has no healthy targets in any target group
- Classic ELB: Has no instances attached

The script only deletes load balancers that are BOTH inactive AND older than the specified age.

Usage:
    python delete_inactive_load_balancers.py --region us-east-1 [--dry-run] [--min-age-days 2]
"""

import argparse
import boto3
import sys
from datetime import datetime, timezone
from typing import List, Dict, Optional
from botocore.exceptions import ClientError, BotoCoreError


class LoadBalancerCleaner:
    def __init__(self, region: str, dry_run: bool = True, min_age_days: int = 2, 
                 filter_tag_key: Optional[str] = None, filter_tag_value: Optional[str] = None):
        """
        Initialize the load balancer cleaner.
        
        Args:
            region: AWS region name
            dry_run: If True, only list inactive LBs without deleting
            min_age_days: Minimum age in days for a load balancer to be eligible for deletion
            filter_tag_key: Tag key to filter on (e.g., 'Owner')
            filter_tag_value: Tag value to filter on (e.g., 'ex_admin@cloudera.com')
        """
        self.region = region
        self.dry_run = dry_run
        self.min_age_days = min_age_days
        self.filter_tag_key = filter_tag_key
        self.filter_tag_value = filter_tag_value
        
        try:
            self.elbv2_client = boto3.client('elbv2', region_name=region)
            self.elb_client = boto3.client('elb', region_name=region)
        except Exception as e:
            print(f"Error initializing AWS clients: {e}")
            sys.exit(1)
    
    def get_all_load_balancers_v2(self) -> List[Dict]:
        """Get all Application and Network Load Balancers (ELBv2)."""
        try:
            response = self.elbv2_client.describe_load_balancers()
            return response.get('LoadBalancers', [])
        except ClientError as e:
            print(f"Error listing ELBv2 load balancers: {e}")
            return []
    
    def get_target_groups_for_lb(self, load_balancer_arn: str) -> List[Dict]:
        """Get all target groups associated with a load balancer."""
        try:
            response = self.elbv2_client.describe_target_groups(
                LoadBalancerArn=load_balancer_arn
            )
            return response.get('TargetGroups', [])
        except ClientError as e:
            print(f"Error getting target groups for {load_balancer_arn}: {e}")
            return []
    
    def has_active_targets(self, target_group_arn: str) -> bool:
        """Check if a target group has any healthy or draining targets."""
        try:
            response = self.elbv2_client.describe_target_health(
                TargetGroupArn=target_group_arn
            )
            targets = response.get('TargetHealthDescriptions', [])
            
            # Check for any targets that are healthy, initial, or draining
            active_states = ['healthy', 'initial', 'draining']
            for target in targets:
                state = target.get('TargetHealth', {}).get('State', '').lower()
                if state in active_states:
                    return True
            return False
        except ClientError as e:
            print(f"Error checking target health for {target_group_arn}: {e}")
            return False
    
    def is_elbv2_inactive(self, load_balancer: Dict) -> bool:
        """
        Check if an ELBv2 load balancer is inactive.
        A load balancer is inactive if it has no active targets in any target group.
        """
        lb_arn = load_balancer['LoadBalancerArn']
        target_groups = self.get_target_groups_for_lb(lb_arn)
        
        # If no target groups, consider it inactive
        if not target_groups:
            return True
        
        # Check if any target group has active targets
        for tg in target_groups:
            if self.has_active_targets(tg['TargetGroupArn']):
                return False
        
        return True
    
    def get_all_classic_load_balancers(self) -> List[Dict]:
        """Get all Classic Load Balancers."""
        try:
            response = self.elb_client.describe_load_balancers()
            return response.get('LoadBalancerDescriptions', [])
        except ClientError as e:
            print(f"Error listing Classic ELBs: {e}")
            return []
    
    def is_classic_elb_inactive(self, load_balancer: Dict) -> bool:
        """
        Check if a Classic ELB is inactive.
        A Classic ELB is inactive if it has no instances attached.
        """
        instances = load_balancer.get('Instances', [])
        return len(instances) == 0
    
    def get_age_days(self, created_time: datetime) -> float:
        """
        Calculate the age of a load balancer in days.
        
        Args:
            created_time: datetime object representing creation time
            
        Returns:
            Age in days as a float
        """
        if created_time.tzinfo is None:
            # If no timezone info, assume UTC
            created_time = created_time.replace(tzinfo=timezone.utc)
        
        now = datetime.now(timezone.utc)
        age_delta = now - created_time
        return age_delta.total_seconds() / 86400.0  # Convert to days
    
    def is_older_than_threshold(self, created_time: datetime) -> bool:
        """
        Check if a load balancer is older than the minimum age threshold.
        
        Args:
            created_time: datetime object representing creation time
            
        Returns:
            True if older than min_age_days, False otherwise
        """
        age_days = self.get_age_days(created_time)
        return age_days >= self.min_age_days
    
    def get_elbv2_tags(self, load_balancer_arn: str) -> Dict[str, str]:
        """Get tags for an ELBv2 load balancer."""
        try:
            response = self.elbv2_client.describe_tags(ResourceArns=[load_balancer_arn])
            if response.get('TagDescriptions'):
                tags = response['TagDescriptions'][0].get('Tags', [])
                return {tag['Key']: tag['Value'] for tag in tags}
            return {}
        except ClientError as e:
            print(f"Error getting tags for {load_balancer_arn}: {e}")
            return {}
    
    def get_classic_elb_tags(self, load_balancer_name: str) -> Dict[str, str]:
        """Get tags for a Classic ELB."""
        try:
            response = self.elb_client.describe_tags(LoadBalancerNames=[load_balancer_name])
            if response.get('TagDescriptions'):
                tags = response['TagDescriptions'][0].get('Tags', [])
                return {tag['Key']: tag['Value'] for tag in tags}
            return {}
        except ClientError as e:
            print(f"Error getting tags for {load_balancer_name}: {e}")
            return {}
    
    def has_required_tag(self, tags: Dict[str, str]) -> bool:
        """
        Check if load balancer has the required tag.
        
        Args:
            tags: Dictionary of tag key-value pairs
            
        Returns:
            True if tag filter matches, or if no filter is set
        """
        if not self.filter_tag_key:
            return True  # No tag filter, accept all
        
        tag_value = tags.get(self.filter_tag_key)
        if tag_value is None:
            return False
        
        if self.filter_tag_value:
            return tag_value == self.filter_tag_value
        else:
            return True  # Tag key exists, value doesn't matter
    
    def get_deletion_protection(self, load_balancer_arn: str) -> bool:
        """Check if deletion protection is enabled on an ELBv2."""
        try:
            response = self.elbv2_client.describe_load_balancer_attributes(
                LoadBalancerArn=load_balancer_arn
            )
            attributes = response.get('Attributes', [])
            for attr in attributes:
                if attr['Key'] == 'deletion_protection.enabled':
                    return attr['Value'].lower() == 'true'
            return False
        except ClientError as e:
            print(f"Error checking deletion protection for {load_balancer_arn}: {e}")
            return False
    
    def disable_deletion_protection(self, load_balancer_arn: str) -> bool:
        """Disable deletion protection on an ELBv2."""
        try:
            self.elbv2_client.modify_load_balancer_attributes(
                LoadBalancerArn=load_balancer_arn,
                Attributes=[
                    {
                        'Key': 'deletion_protection.enabled',
                        'Value': 'false'
                    }
                ]
            )
            return True
        except ClientError as e:
            print(f"Error disabling deletion protection for {load_balancer_arn}: {e}")
            return False
    
    def delete_elbv2(self, load_balancer_arn: str, check_protection: bool = True) -> bool:
        """Delete an ELBv2 load balancer."""
        if check_protection:
            if self.get_deletion_protection(load_balancer_arn):
                print(f"  Deletion protection enabled. Disabling it first...")
                if not self.disable_deletion_protection(load_balancer_arn):
                    print(f"  Failed to disable deletion protection. Skipping deletion.")
                    return False
        
        try:
            self.elbv2_client.delete_load_balancer(LoadBalancerArn=load_balancer_arn)
            print(f"  ✓ Deleted: {load_balancer_arn}")
            return True
        except ClientError as e:
            print(f"  ✗ Error deleting {load_balancer_arn}: {e}")
            return False
    
    def delete_classic_elb(self, load_balancer_name: str) -> bool:
        """Delete a Classic ELB."""
        try:
            self.elb_client.delete_load_balancer(LoadBalancerName=load_balancer_name)
            print(f"  ✓ Deleted: {load_balancer_name}")
            return True
        except ClientError as e:
            print(f"  ✗ Error deleting {load_balancer_name}: {e}")
            return False
    
    def find_and_delete_inactive_lbs(self, check_protection: bool = True):
        """Find and delete all inactive load balancers older than min_age_days with required tag."""
        print(f"\n{'='*70}")
        print(f"Scanning for inactive load balancers in region: {self.region}")
        print(f"Minimum age for deletion: {self.min_age_days} days")
        if self.filter_tag_key:
            tag_filter = f"{self.filter_tag_key}={self.filter_tag_value}" if self.filter_tag_value else self.filter_tag_key
            print(f"Tag filter: {tag_filter}")
        else:
            print("Tag filter: None (all load balancers)")
        print(f"Mode: {'DRY RUN (no deletions)' if self.dry_run else 'DELETE MODE'}")
        print(f"{'='*70}\n")
        
        deleted_count = 0
        skipped_count = 0
        
        # Process ELBv2 (ALB/NLB)
        print("\n[1/2] Checking ELBv2 Load Balancers (ALB/NLB)...")
        elbv2_lbs = self.get_all_load_balancers_v2()
        print(f"Found {len(elbv2_lbs)} ELBv2 load balancer(s)")
        
        inactive_elbv2 = []
        too_new_elbv2 = []
        skipped_no_created_time = 0
        skipped_no_tag = 0
        for lb in elbv2_lbs:
            lb_name = lb.get('LoadBalancerName', 'Unknown')
            lb_arn = lb.get('LoadBalancerArn', 'Unknown')
            lb_type = lb.get('Type', 'Unknown')
            created_time = lb.get('CreatedTime')
            
            # Check tags first
            tags = self.get_elbv2_tags(lb_arn)
            if not self.has_required_tag(tags):
                skipped_no_tag += 1
                tag_display = f"{self.filter_tag_key}={tags.get(self.filter_tag_key, 'N/A')}" if self.filter_tag_key else "N/A"
                print(f"  ⊘ Skipped (tag mismatch): {lb_name} ({lb_type}) - tag: {tag_display}")
                continue
            
            if created_time:
                age_days = self.get_age_days(created_time)
                is_inactive = self.is_elbv2_inactive(lb)
                is_old_enough = self.is_older_than_threshold(created_time)
                
                if is_inactive:
                    if is_old_enough:
                        inactive_elbv2.append(lb)
                        print(f"  → Inactive & eligible: {lb_name} ({lb_type}) - {lb_arn} (age: {age_days:.1f} days)")
                    else:
                        too_new_elbv2.append((lb_name, age_days))
                        print(f"  → Inactive but too new: {lb_name} ({lb_type}) - {lb_arn} (age: {age_days:.1f} days, need {self.min_age_days} days)")
            else:
                skipped_no_created_time += 1
                print(f"  ⚠ Skipped {lb_name} ({lb_type}): No creation time available")
        
        if inactive_elbv2:
            print(f"\nFound {len(inactive_elbv2)} inactive ELBv2 load balancer(s) older than {self.min_age_days} days")
            for lb in inactive_elbv2:
                lb_name = lb.get('LoadBalancerName', 'Unknown')
                lb_arn = lb.get('LoadBalancerArn', 'Unknown')
                created_time = lb.get('CreatedTime')
                age_days = self.get_age_days(created_time) if created_time else 0
                
                if self.dry_run:
                    print(f"  [DRY RUN] Would delete: {lb_name} ({lb_arn}) - age: {age_days:.1f} days")
                else:
                    print(f"\nDeleting: {lb_name} (age: {age_days:.1f} days)")
                    if self.delete_elbv2(lb_arn, check_protection):
                        deleted_count += 1
                    else:
                        skipped_count += 1
        else:
            print("No inactive ELBv2 load balancers found that are older than {} days.".format(self.min_age_days))
        
        if too_new_elbv2:
            print(f"\nNote: {len(too_new_elbv2)} inactive ELBv2 load balancer(s) are too new to delete (need {self.min_age_days} days)")
        if skipped_no_created_time > 0:
            print(f"\nNote: {skipped_no_created_time} ELBv2 load balancer(s) skipped (no creation time available)")
        if skipped_no_tag > 0:
            tag_filter = f"{self.filter_tag_key}={self.filter_tag_value}" if self.filter_tag_key and self.filter_tag_value else self.filter_tag_key
            print(f"\nNote: {skipped_no_tag} ELBv2 load balancer(s) skipped (tag filter mismatch: {tag_filter})")
        
        # Process Classic ELB
        print("\n[2/2] Checking Classic Load Balancers...")
        classic_lbs = self.get_all_classic_load_balancers()
        print(f"Found {len(classic_lbs)} Classic load balancer(s)")
        
        inactive_classic = []
        too_new_classic = []
        skipped_no_created_time_classic = 0
        skipped_no_tag_classic = 0
        for lb in classic_lbs:
            lb_name = lb.get('LoadBalancerName', 'Unknown')
            instance_count = len(lb.get('Instances', []))
            created_time = lb.get('CreatedTime')
            
            # Check tags first
            tags = self.get_classic_elb_tags(lb_name)
            if not self.has_required_tag(tags):
                skipped_no_tag_classic += 1
                tag_display = f"{self.filter_tag_key}={tags.get(self.filter_tag_key, 'N/A')}" if self.filter_tag_key else "N/A"
                print(f"  ⊘ Skipped (tag mismatch): {lb_name} - tag: {tag_display}")
                continue
            
            if created_time:
                age_days = self.get_age_days(created_time)
                is_inactive = self.is_classic_elb_inactive(lb)
                is_old_enough = self.is_older_than_threshold(created_time)
                
                if is_inactive:
                    if is_old_enough:
                        inactive_classic.append(lb)
                        print(f"  → Inactive & eligible: {lb_name} (0 instances, age: {age_days:.1f} days)")
                    else:
                        too_new_classic.append((lb_name, age_days))
                        print(f"  → Inactive but too new: {lb_name} (0 instances, age: {age_days:.1f} days, need {self.min_age_days} days)")
            else:
                skipped_no_created_time_classic += 1
                print(f"  ⚠ Skipped {lb_name}: No creation time available")
        
        if inactive_classic:
            print(f"\nFound {len(inactive_classic)} inactive Classic load balancer(s) older than {self.min_age_days} days")
            for lb in inactive_classic:
                lb_name = lb.get('LoadBalancerName', 'Unknown')
                created_time = lb.get('CreatedTime')
                age_days = self.get_age_days(created_time) if created_time else 0
                
                if self.dry_run:
                    print(f"  [DRY RUN] Would delete: {lb_name} - age: {age_days:.1f} days")
                else:
                    print(f"\nDeleting: {lb_name} (age: {age_days:.1f} days)")
                    if self.delete_classic_elb(lb_name):
                        deleted_count += 1
                    else:
                        skipped_count += 1
        else:
            print("No inactive Classic load balancers found that are older than {} days.".format(self.min_age_days))
        
        if too_new_classic:
            print(f"\nNote: {len(too_new_classic)} inactive Classic load balancer(s) are too new to delete (need {self.min_age_days} days)")
        if skipped_no_created_time_classic > 0:
            print(f"\nNote: {skipped_no_created_time_classic} Classic load balancer(s) skipped (no creation time available)")
        if skipped_no_tag_classic > 0:
            tag_filter = f"{self.filter_tag_key}={self.filter_tag_value}" if self.filter_tag_key and self.filter_tag_value else self.filter_tag_key
            print(f"\nNote: {skipped_no_tag_classic} Classic load balancer(s) skipped (tag filter mismatch: {tag_filter})")
        
        # Summary
        print(f"\n{'='*70}")
        print("SUMMARY")
        print(f"{'='*70}")
        if self.dry_run:
            total_inactive = len(inactive_elbv2) + len(inactive_classic)
            print(f"Total inactive load balancers (older than {self.min_age_days} days): {total_inactive}")
            print(f"  - ELBv2: {len(inactive_elbv2)}")
            print(f"  - Classic: {len(inactive_classic)}")
            total_too_new = len(too_new_elbv2) + len(too_new_classic)
            if total_too_new > 0:
                print(f"\nInactive but too new (< {self.min_age_days} days): {total_too_new}")
                print(f"  - ELBv2: {len(too_new_elbv2)}")
                print(f"  - Classic: {len(too_new_classic)}")
            total_skipped_tag = skipped_no_tag + skipped_no_tag_classic
            if total_skipped_tag > 0 and self.filter_tag_key:
                tag_filter = f"{self.filter_tag_key}={self.filter_tag_value}" if self.filter_tag_value else self.filter_tag_key
                print(f"\nSkipped due to tag filter ({tag_filter}): {total_skipped_tag}")
                print(f"  - ELBv2: {skipped_no_tag}")
                print(f"  - Classic: {skipped_no_tag_classic}")
            print("\nRun with --no-dry-run to actually delete these load balancers.")
        else:
            print(f"Deleted: {deleted_count}")
            print(f"Skipped: {skipped_count}")
            print(f"Total processed: {deleted_count + skipped_count}")
        print(f"{'='*70}\n")


def main():
    parser = argparse.ArgumentParser(
        description='Delete inactive load balancers from AWS account that are older than specified days',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Dry run to see what would be deleted (default: 2 days, Owner=ex_admin@cloudera.com)
  python delete_inactive_load_balancers.py --region us-east-1

  # Actually delete inactive load balancers older than 2 days with Owner tag
  python delete_inactive_load_balancers.py --region us-east-1 --no-dry-run

  # Use custom minimum age (e.g., 7 days)
  python delete_inactive_load_balancers.py --region us-east-1 --min-age-days 7 --no-dry-run

  # Use custom tag filter
  python delete_inactive_load_balancers.py --region us-east-1 --filter-tag-key Owner --filter-tag-value ex_admin@cloudera.com --no-dry-run

  # Disable tag filtering (process all load balancers)
  python delete_inactive_load_balancers.py --region us-east-1 --no-tag-filter --no-dry-run

  # Skip deletion protection check (faster but may fail if protection is enabled)
  python delete_inactive_load_balancers.py --region us-east-1 --no-dry-run --skip-protection-check
        """
    )
    
    parser.add_argument(
        '--region',
        required=True,
        help='AWS region (e.g., us-east-1, eu-west-1)'
    )
    
    parser.add_argument(
        '--no-dry-run',
        action='store_true',
        default=False,
        help='Actually delete load balancers (default: dry-run mode)'
    )
    
    parser.add_argument(
        '--min-age-days',
        type=int,
        default=2,
        help='Minimum age in days for a load balancer to be eligible for deletion (default: 2)'
    )
    
    parser.add_argument(
        '--skip-protection-check',
        action='store_true',
        default=False,
        help='Skip checking and disabling deletion protection (faster but may fail)'
    )
    
    parser.add_argument(
        '--filter-tag-key',
        type=str,
        default='Owner',
        help='Tag key to filter load balancers (default: Owner)'
    )
    
    parser.add_argument(
        '--filter-tag-value',
        type=str,
        default='ex_admin@cloudera.com',
        help='Tag value to filter load balancers (default: ex_admin@cloudera.com)'
    )
    
    parser.add_argument(
        '--no-tag-filter',
        action='store_true',
        default=False,
        help='Disable tag filtering (process all load balancers regardless of tags)'
    )
    
    args = parser.parse_args()
    
    # Validate min_age_days
    if args.min_age_days < 0:
        print("Error: --min-age-days must be non-negative")
        sys.exit(1)
    
    # Set tag filter parameters
    tag_key = None if args.no_tag_filter else args.filter_tag_key
    tag_value = None if args.no_tag_filter else args.filter_tag_value
    
    # Confirm deletion if not in dry-run mode
    if not args.no_dry_run:
        print("Running in DRY RUN mode. No load balancers will be deleted.")
        print(f"Minimum age threshold: {args.min_age_days} days")
        if tag_key:
            tag_filter = f"{tag_key}={tag_value}" if tag_value else tag_key
            print(f"Tag filter: {tag_filter}")
        else:
            print("Tag filter: None (all load balancers)")
        print("Use --no-dry-run to actually perform deletions.\n")
    else:
        tag_filter_str = f" with tag {tag_key}={tag_value}" if tag_key and tag_value else ""
        response = input(f"⚠️  WARNING: This will DELETE inactive load balancers older than {args.min_age_days} days{tag_filter_str}. Continue? (yes/no): ")
        if response.lower() != 'yes':
            print("Aborted.")
            sys.exit(0)
    
    cleaner = LoadBalancerCleaner(
        region=args.region,
        dry_run=not args.no_dry_run,
        min_age_days=args.min_age_days,
        filter_tag_key=tag_key,
        filter_tag_value=tag_value
    )
    
    cleaner.find_and_delete_inactive_lbs(check_protection=not args.skip_protection_check)


if __name__ == '__main__':
    main()

