# HNG13 Stage 1 DevOps Task - Automated Deployment Script

## Overview
This is an automated deployment script that handles the complete deployment process of a Dockerized application to a remote Ubuntu server. It includes repository cloning, Docker container deployment, and Nginx reverse proxy configuration.

## Prerequisites
- Local machine with Bash shell
- Git installed locally
- Remote Ubuntu server with SSH access
- SSH key for authentication
- GitHub Personal Access Token (PAT)

## What the Script Does
1. Collects deployment parameters (repo URL, PAT, server details, etc.)
2. Clones or updates the Git repository
3. Verifies Docker configuration files exist
4. Tests SSH connection to remote server
5. Installs Docker, Docker Compose, and Nginx on remote server
6. Transfers project files to the server
7. Builds and runs Docker containers
8. Configures Nginx as a reverse proxy
9. Validates the entire deployment

## Usage

### Make the script executable:
```bash
chmod +x deploy.sh
```

### Run the script:
```bash
./deploy.sh
```

### Follow the prompts to enter:
- Git repository URL
- Personal Access Token
- Branch name (press Enter for 'main')
- Remote server username
- Server IP address
- SSH key path (press Enter for default ~/.ssh/id_rsa)
- Application port (press Enter for default 3000)

## Logs
All deployment actions are logged to a timestamped file in the format:
```
deploy_YYYYMMDD_HHMMSS.log
```

Each log entry includes:
- Timestamp
- Action being performed
- Success or error messages
- Command outputs

## Error Handling
The script includes:
- Input validation for all parameters
- SSH connection testing before deployment
- Docker file verification
- Container health checks
- Nginx configuration testing
- Detailed error messages with line numbers

## Idempotency
The script can be safely run multiple times:
- Pulls latest changes if repository exists
- Stops old containers before deploying new ones
- Updates Nginx configuration without duplicates
- Checks for existing installations before installing

## Project Structure
```
hng13-stage1-devops/
├── deploy.sh          # Main deployment script
├── README.md          # This file
└── deploy_*.log       # Generated log files
```

## Author
LydiahLaw

## Repository
https://github.com/LydiahLaw/hng13-stage1-devops

## License
This script is shared as part of the HNG DevOps Stage 1 task.
