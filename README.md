# gazeebo
gazeeebollc

# Gazeebo — Private Photo Vault

A serverless private photo vault powered by AWS (S3, API Gateway, Lambda, DynamoDB, and Cognito) and deployed using Terraform.

## Project Structure

- `backend.tf` — Terraform S3 state backend configuration.
- `versions.tf` — Terraform and provider version constraints.
- `variables.tf` — Input variables for region, table names, and expiration parameters.
- `main.tf` — AWS infrastructure setup (S3, IAM, Lambda, API Gateway HTTP API).
- `outputs.tf` — Output values for API endpoints and bucket details.
- `index.html` — Authentication dashboard / login page.
- `photos.html` — Main photo vault page (Upload, List, Delete images via S3 pre-signed URLs).

## Deployment Instructions

1. **Initialize Terraform:**
   ```bash
   terraform init
