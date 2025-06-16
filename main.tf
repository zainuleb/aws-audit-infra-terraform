provider "aws" {
  region = "us-east-1"
}

data "aws_caller_identity" "current" {}

# Random ID for unique bucket names
resource "random_id" "suffix" {
  byte_length = 4
}

# S3 Bucket for CloudTrail & AWS Config Logs
resource "aws_s3_bucket" "cloudtrail_logs" {
  bucket         = "${var.project_name}-${var.environment}-${random_id.suffix.hex}"
  force_destroy  = true

  tags = {
    Name = "CloudTrailLogs"
  }
}

# S3 Bucket Policy for CloudTrail and AWS Config
resource "aws_s3_bucket_policy" "cloudtrail_logs_policy" {
  bucket = aws_s3_bucket.cloudtrail_logs.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      # CloudTrail permissions
      {
        Sid       = "AWSCloudTrailAclCheck20150319",
        Effect    = "Allow",
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        },
        Action    = "s3:GetBucketAcl",
        Resource  = aws_s3_bucket.cloudtrail_logs.arn
      },
      {
        Sid       = "AWSCloudTrailWrite20150319",
        Effect    = "Allow",
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        },
        Action    = "s3:PutObject",
        Resource  = "${aws_s3_bucket.cloudtrail_logs.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*",
        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
          }
        }
      },
      # AWS Config permissions
      {
        Sid       = "AWSConfigBucketPermissionsCheck",
        Effect    = "Allow",
        Principal = {
          Service = "config.amazonaws.com"
        },
        Action    = "s3:GetBucketAcl",
        Resource  = aws_s3_bucket.cloudtrail_logs.arn
      },
      {
        Sid       = "AWSConfigBucketDelivery",
        Effect    = "Allow",
        Principal = {
          Service = "config.amazonaws.com"
        },
        Action    = "s3:PutObject",
        Resource  = "${aws_s3_bucket.cloudtrail_logs.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*",
        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
          }
        }
      }
    ]
  })
}

# Block Public Access to S3 Bucket
resource "aws_s3_bucket_public_access_block" "block" {
  bucket                  = aws_s3_bucket.cloudtrail_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Enable Versioning on the S3 Bucket
resource "aws_s3_bucket_versioning" "versioning" {
  bucket = aws_s3_bucket.cloudtrail_logs.id

  versioning_configuration {
    status = "Enabled"
  }
}

# CloudWatch Log Group for CloudTrail
resource "aws_cloudwatch_log_group" "trail_logs" {
  name              = "/aws/cloudtrail/${var.project_name}"
  retention_in_days = 90
}

# IAM Role for CloudTrail to send logs to CloudWatch
resource "aws_iam_role" "cloudtrail_role" {
  name = "cloudtrail-to-cloudwatch"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Action    = "sts:AssumeRole",
      Principal = {
        Service = "cloudtrail.amazonaws.com"
      }
    }]
  })
}

# IAM Policy for CloudTrail Log Permissions
resource "aws_iam_role_policy" "cloudtrail_policy" {
  name = "cloudtrail-policy"
  role = aws_iam_role.cloudtrail_role.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect   = "Allow",
      Action   = [
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      Resource = "*"
    }]
  })
}

# CloudTrail Setup
resource "aws_cloudtrail" "trail" {
  name                          = "cloudtrail-${var.project_name}"
  s3_bucket_name                = aws_s3_bucket.cloudtrail_logs.id
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_log_file_validation    = true
  cloud_watch_logs_group_arn    = "${aws_cloudwatch_log_group.trail_logs.arn}:*"
  cloud_watch_logs_role_arn     = aws_iam_role.cloudtrail_role.arn

  event_selector {
    read_write_type           = "All"
    include_management_events = true
  }

  depends_on = [aws_s3_bucket_public_access_block.block]
}

# IAM Role for AWS Config
resource "aws_iam_role" "config_role" {
  name = "config-recorder-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Action    = "sts:AssumeRole",
      Principal = {
        Service = "config.amazonaws.com"
      }
    }]
  })
}

# Attach AWS Managed Policy to Config Role
resource "aws_iam_role_policy_attachment" "config_attach" {
  role       = aws_iam_role.config_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSConfigRoleForOrganizations"
}


# AWS Config Recorder
resource "aws_config_configuration_recorder" "recorder" {
  name     = "config-recorder"
  role_arn = aws_iam_role.config_role.arn

  recording_group {
    all_supported              = true
    include_global_resource_types = true
  }
}

# AWS Config Delivery Channel
resource "aws_config_delivery_channel" "channel" {
  name           = "config-delivery"
  s3_bucket_name = aws_s3_bucket.cloudtrail_logs.bucket
}

# Start AWS Config Recorder
resource "aws_config_configuration_recorder_status" "recorder_status" {
  name       = aws_config_configuration_recorder.recorder.name
  is_enabled = true

  depends_on = [aws_config_delivery_channel.channel]
}
