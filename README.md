# AUTOMATED DEPLOYMENT BASH SCRIPT

## Overview

This repository contains an automated Bash deployment script (`deploy.sh`) created for the _HNG13 DevOps Internship Stage 1 task_.  
The script automates the setup, deployment, and configuration of a Dockerized application on a remote Linux server.  
It provides a production-grade, repeatable, and reliable workflow similar to real-world DevOps environments.

## FEATURES

* Collects and validates user input (GitHub repository, Personal Access Token, SSH details, application port)
* Clones or updates the target GitHub repository
* Checks for the presence of a `Dockerfile` or `docker-compose.yml`
* Connects securely to a remote server via SSH
* Installs and configures Docker, Docker Compose, and Nginx
* Builds and runs containers
* Configures Nginx as a reverse proxy
* Validates deployment and logs all steps
* Supports safe re-runs (idempotent behavior)

## USAGE

1. Make the script executable:

   ```bash
   chmod +x deploy.sh
   ```

2. Run the script:

   ```bash
   ./deploy.sh
   ```

3. Follow the prompts to enter:

   * GitHub username/repo (for example, `coolkeeds/myapp`)
   * Personal Access Token (input is hidden)
   * Branch name (defaults to `main`)
   * SSH username, server IP, and SSH key path
   * Application internal port

4. The script will:

   * Clone the repository
   * Connect to the remote host via SSH
   * Install required tools
   * Deploy and start the Dockerized application
   * Configure Nginx as a reverse proxy
   * Validate the running service

## REQUIREMENTS

* Local machine with:

  * `bash` or `sh`
  * `git`
  * SSH access to a remote server
* Remote server with:

  * Ubuntu or Debian (recommended)
  * Internet access and sudo privileges

## LOGGING

Each execution generates a timestamped log file:

```
deploy_YYYYMMDD_HHMMSS.log
```

All actions, success messages, and errors are recorded for later review.

## RE-RUNS AND CLEANUP

The script is idempotent, meaning it can be safely re-run without breaking existing deployments.
An optional `--cleanup` flag can be used to remove containers, networks, and configurations created during deployment.

Example:

```bash
./deploy.sh --cleanup
```

## AUTHOR

**Full Name:** Kevin Mwangi  
**Slack Username:** Kevin Mwangi  
**HNG13 DevOps Intern (Stage 1)**  
**GitHub:** [Github repo](https://github.com/mwangiii/hng-devops-task-one.git)
