<#
.SYNOPSIS
    Bootstraps Terraform remote backend infrastructure for this repository.

.DESCRIPTION
    This script creates the AWS S3 bucket and DynamoDB table required
    for Terraform remote state and state locking.

    Terraform CANNOT create its own backend (because 'terraform init'
    must connect to an existing backend before any resources can be created).

    Therefore, backend infrastructure must be created manually or via a script
    like this one BEFORE running 'terraform init' in any project folder.

    This script:
      - Creates S3 bucket for remote state
      - Enables S3 bucket versioning
      - Enables server-side AES256 encryption
      - Tags the bucket
      - Creates DynamoDB table for state locking
      - Waits for the table to be active
      - Prints the backend.tf block you should use

    Run this once per AWS account/environment.

.NOTES
    Author: DevOps Raf (@TerminalsandCoffee)
    Platform: Windows PowerShell (PS1)
    Dependencies: AWS CLI configured with valid credentials
    Run once per AWS account (dev/staging/prod) before first `terraform init

.EXAMPLE
    PS> ./bootstrap-backend.ps1
#>

# ===============================
# Config - override via env vars if needed
# ===============================
# If you're on PS 7+, the ?? operators are fine.
$Region          = $env:AWS_REGION         ?? "us-east-1"
$Project         = $env:TF_BACKEND_PROJECT ?? "aws-devops-portfolio"
$Owner           = $env:TF_BACKEND_OWNER   ?? "rafael-martinez"
$Environment     = $env:TF_ENV             ?? "global"

# Make bucket name globally unique and DNS-compliant
$AccountId       = aws sts get-caller-identity --query Account --output text
$BucketName      = "$Project-terraform-state-$AccountId".ToLower()
$DynamoTable     = "$Project-terraform-locks-$Environment".ToLower()

Write-Host "`n=== Terraform Backend Bootstrap (Account: $AccountId | Region: $Region) ===`n" -ForegroundColor Cyan

# -------------------------------
# 1. S3 Bucket (idempotent)
# -------------------------------
Write-Host "Ensuring S3 bucket: $BucketName" -ForegroundColor Cyan

if (aws s3api head-bucket --bucket $BucketName --region $Region 2>$null) {
    Write-Host "Bucket already exists, skipping creation" -ForegroundColor Yellow
} else {
    Write-Host "Creating bucket..." -ForegroundColor Cyan
    aws s3api create-bucket `
        --bucket $BucketName `
        --region $Region `
        --create-bucket-configuration LocationConstraint=$Region `
        --object-ownership BucketOwnerEnforced | Out-Null

    # Block all public access (security best practice)
    aws s3api put-public-access-block `
        --bucket $BucketName `
        --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
}

# Always ensure best-practice settings (idempotent)
Write-Host "Applying bucket security & versioning..." -ForegroundColor Cyan
aws s3api put-bucket-versioning --bucket $BucketName --versioning-configuration Status=Enabled | Out-Null
aws s3api put-bucket-encryption --bucket $BucketName `
    --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}' | Out-Null

# Tagging
aws s3api put-bucket-tagging --bucket $BucketName `
    --tagging "TagSet=[{Key=Project,Value=$Project},{Key=Owner,Value=$Owner},{Key=Environment,Value=$Environment},{Key=ManagedBy,Value=BootstrapScript}]" | Out-Null

# -------------------------------
# 2. DynamoDB Lock Table (idempotent)
# -------------------------------
Write-Host "`nEnsuring DynamoDB lock table: $DynamoTable" -ForegroundColor Cyan

$tableStatus = aws dynamodb describe-table --table-name $DynamoTable --region $Region --query "Table.TableStatus" --output text 2>$null
if ($tableStatus) {
    Write-Host "Table already exists (status: $tableStatus)" -ForegroundColor Yellow
} else {
    Write-Host "Creating DynamoDB table with on-demand billing..." -ForegroundColor Cyan
    aws dynamodb create-table `
        --table-name $DynamoTable `
        --attribute-definitions AttributeName=LockID,AttributeType=S `
        --key-schema AttributeName=LockID,KeyType=HASH `
        --billing-mode PAY_PER_REQUEST `
        --region $Region | Out-Null

    Write-Host "Waiting for table to become ACTIVE..." -ForegroundColor Yellow
    aws dynamodb wait table-exists --table-name $DynamoTable --region $Region
    Start-Sleep -Seconds 3  # small extra wait for eventual consistency
}

# -------------------------------
# 3. Output ready-to-paste backend block
# -------------------------------
Write-Host "`nBackend infrastructure ready!" -ForegroundColor Green
Write-Host "`nCopy the block below into backend.tf (or each module's backend.tf):`n" -ForegroundColor Green

$backendBlock = @"
terraform {
  backend "s3" {
    bucket         = "$BucketName"
    key            = "global/terraform.tfstate"   # change per project/folder as needed
    region         = "$Region"
    dynamodb_table = "$DynamoTable"
    encrypt        = true
  }
}
"@

Write-Host $backendBlock -ForegroundColor White

Write-Host "`nYou can now run: terraform init`n" -ForegroundColor Green
Write-Host "=== Bootstrap complete! ===`n" -ForegroundColor Cyan