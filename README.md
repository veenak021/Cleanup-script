# Subnet Tags Management Project

This project contains scripts and tools for managing AWS subnet tags, including a web UI for tag deletion operations.

## Project Structure

```
subnet-tags-project/
├── delete_subnet_tags.sh          # Main script for deleting subnet tags
├── subnet_tags_ui/                # Web UI application
│   ├── app.py                     # Flask backend
│   ├── templates/                 # HTML templates
│   └── k8s/                       # Kubernetes deployment files
├── debug_subnet_tags.sh           # Debugging utilities
├── delete_specific_subnet_tag.sh  # Script for specific tag deletion
├── quick_delete_subnet_tag.sh     # Quick tag deletion script
├── list_old_aws_instances.sh      # List old AWS instances
├── delete_inactive_load_balancers.py  # Delete inactive load balancers
└── test_tag_value.sh              # Test tag values
```

## Features

### 1. Subnet Tags Deletion Script
- Delete specific tags from AWS subnets
- Delete Kubernetes cluster tags (`kubernetes.io/cluster/*`)
- Support for multiple regions and subnet IDs
- Dry-run mode for testing

### 2. Web UI Application
- User-friendly web interface for subnet tag management
- Flask-based backend
- Supports multiple deployment options:
  - Local development
  - Docker containers
  - Kubernetes pods
  - AWS EC2 instances

## Quick Start

### Local Development

```bash
cd subnet_tags_ui
./start.sh
```

### Docker Deployment

```bash
cd subnet_tags_ui
docker-compose up
```

### Kubernetes Deployment

```bash
cd subnet_tags_ui/k8s
./deploy_k8s.sh
```

## Requirements

- Python 3.8+
- AWS CLI configured
- kubectl (for Kubernetes deployment)
- Docker (for containerized deployment)

## Documentation

- [Local Development](subnet_tags_ui/README.md)
- [AWS Deployment](subnet_tags_ui/DEPLOY_AWS.md)
- [Docker Deployment](subnet_tags_ui/DEPLOY_DOCKER.md)
- [Kubernetes Deployment](subnet_tags_ui/k8s/DEPLOY_K8S.md)
- [Pod-Based Deployment (No SSH)](subnet_tags_ui/k8s/DEPLOY_POD.md)

## Scripts

### delete_subnet_tags.sh
Main script for deleting tags from AWS subnets.

**Usage:**
```bash
./delete_subnet_tags.sh --region us-west-2 --subnet-ids subnet-12345 --tag-keys Environment,Project
./delete_subnet_tags.sh --region us-west-2 --kubernetes-cluster-tags
```

**Options:**
- `--region REGION`: AWS region
- `--subnet-ids IDS`: Comma-separated subnet IDs
- `--tag-keys KEYS`: Comma-separated tag keys to delete
- `--kubernetes-cluster-tags`: Delete only kubernetes.io/cluster/* tags
- `--dry-run`: Show what would be deleted without actually deleting

## License

This project is part of the CDP E2E Interop QE repository.

