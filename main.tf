provider "aws" {
  region = "us-west-1"
}

# ==========================================
# 1. S3 BUCKET: FRONTEND WEBSITE HOSTING
# ==========================================
resource "aws_s3_bucket" "website_bucket" {
  bucket = "gazeebo-frontend-portal-${local.account_id}"
}

resource "aws_s3_bucket_public_access_block" "website_block" {
  bucket                  = aws_s3_bucket.website_bucket.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ==========================================
# 2. S3 BUCKET: PRIVATE PHOTO VAULT
# ==========================================
resource "aws_s3_bucket" "photos_bucket" {
  bucket = "gazeebo-private-photos-${local.account_id}"
}

resource "aws_s3_bucket_server_side_encryption_configuration" "photos_encryption" {
  bucket = aws_s3_bucket.photos_bucket.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "photos_block" {
  bucket                  = aws_s3_bucket.photos_bucket.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
# ==========================================
# S3 BUCKET CORS CONFIGURATION
# ==========================================
resource "aws_s3_bucket_cors_configuration" "photos_cors" {
  bucket = aws_s3_bucket.photos_bucket.id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["PUT", "POST", "GET"]
    allowed_origins = [
      "https://main.d1x75slbuwqfiz.amplifyapp.com",
      "http://localhost:3000"
    ]
    expose_headers  = []
  }
}

# ==========================================
# 3. CLOUDFRONT CDN (Secure HTTPS Edge Routing)
# ==========================================
data "aws_caller_identity" "current" {}
locals {
  account_id = data.aws_caller_identity.current.account_id
}

resource "aws_cloudfront_origin_access_control" "oac" {
  name                              = "gazeebo-oac"
  description                       = "OAC for Frontend S3 Bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "cdn" {
  enabled             = true
  default_root_object = "index.html"

  origin {
    domain_name              = aws_s3_bucket.website_bucket.bucket_regional_domain_name
    origin_id                = "S3-Frontend-Origin"
    origin_access_control_id = aws_cloudfront_origin_access_control.oac.id
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "S3-Frontend-Origin"
    viewer_protocol_policy = "redirect-to-https"

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

resource "aws_s3_bucket_policy" "cloudfront_s3_policy" {
  bucket = aws_s3_bucket.website_bucket.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowCloudFrontServicePrincipal"
        Effect    = "Allow"
        Principal = {
          Service = "cloudfront.amazonaws.com"
        }
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.website_bucket.arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.cdn.arn
          }
        }
      }
    ]
  })
}

# ==========================================
# 4. DYNAMODB TABLE (Profiles & Photo Metadata)
# ==========================================
resource "aws_dynamodb_table" "gazeebo_db" {
  name         = "GazeeboPortalData"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "PK"
  range_key    = "SK"

  attribute {
    name = "PK"
    type = "S"
  }

  attribute {
    name = "SK"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }
}

# ==========================================
# 5. AMAZON COGNITO (User Authentication)
# ==========================================
resource "aws_cognito_user_pool" "pool" {
  name = "gazeebo-user-pool"

  auto_verified_attributes = ["email"]

  password_policy {
    minimum_length    = 8
    require_lowercase = true
    require_numbers   = true
    require_symbols   = false
    require_uppercase = true
  }

  schema {
    name                = "email"
    attribute_data_type = "String"
    required            = true
    mutable             = true
  }

  schema {
    name                = "name"
    attribute_data_type = "String"
    required            = true
    mutable             = true
  }
}

resource "aws_cognito_user_pool_client" "client" {
  name                          = "gazeebo-web-client"
  user_pool_id                  = aws_cognito_user_pool.pool.id
  generate_secret               = false
  explicit_auth_flows           = ["ALLOW_USER_PASSWORD_AUTH", "ALLOW_REFRESH_TOKEN_AUTH", "ALLOW_USER_SRP_AUTH"]
  prevent_user_existence_errors = "ENABLED"
}

