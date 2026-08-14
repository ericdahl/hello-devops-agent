terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    # The aws provider has no DevOps Agent resources yet, so the agent space and
    # its association come from awscc (generated from the CloudFormation registry).
    awscc = {
      source  = "hashicorp/awscc"
      version = "~> 1.97"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

provider "aws" {
  region = var.region
}

provider "awscc" {
  region = var.region
}

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}
