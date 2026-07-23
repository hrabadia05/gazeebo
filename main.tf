# ==========================================
# 1. AWS ACCOUNT ID DATA SOURCE & LOCALS
# ==========================================
data "aws_caller_identity" "current" {}

locals {
  account_id           = data.aws_caller_identity.current.account_id
  photos_bucket_name   = "gazeebo-private-photos-${local.account_id}"
  website_bucket_name  = "gazeebo-website-frontend-${local.account_id}"
}

# ==========================================
# 2. S3 BUCKETS (PHOTOS & WEBSITE)
# ==========================================
# Private Photos Bucket
resource "aws_s3_bucket" "photos_bucket" {
  bucket        = local.photos_bucket_name
  force_destroy = false
}

resource "aws_s3_bucket_cors_configuration" "photos_bucket_cors" {
  bucket = aws_s3_bucket.photos_bucket.id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "PUT", "POST", "DELETE", "HEAD"]
    allowed_origins = ["*"]
    max_age_seconds = 3000
  }
}

resource "aws_s3_bucket_public_access_block" "photos_bucket_block" {
  bucket                  = aws_s3_bucket.photos_bucket.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Frontend Website Bucket
resource "aws_s3_bucket" "website_bucket" {
  bucket        = local.website_bucket_name
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "website_bucket_block" {
  bucket                  = aws_s3_bucket.website_bucket.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ==========================================
# 3. COGNITO USER POOL & CLIENT
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
}

resource "aws_cognito_user_pool_client" "client" {
  name         = "gazeebo-web-client"
  user_pool_id = aws_cognito_user_pool.pool.id

  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
    "ALLOW_USER_SRP_AUTH"
  ]
}

# ==========================================
# 4. CLOUDFRONT DISTRIBUTION (OAC FOR S3)
# ==========================================
resource "aws_cloudfront_origin_access_control" "oac" {
  name                              = "gazeebo-website-oac"
  description                       = "OAC for Gazeebo Website S3 Bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "cdn" {
  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"

  origin {
    domain_name              = aws_s3_bucket.website_bucket.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.oac.id
    origin_id                = "S3-${aws_s3_bucket.website_bucket.id}"
  }

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "S3-${aws_s3_bucket.website_bucket.id}"

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
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

# Bucket policy allowing CloudFront OAC read access
resource "aws_s3_bucket_policy" "website_bucket_policy" {
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
# 5. LAMBDA IAM ROLE & POLICIES
# ==========================================
resource "aws_iam_role" "lambda_exec" {
  name = "gazeebo_lambda_exec_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_policy" "lambda_s3_policy" {
  name = "gazeebo_lambda_s3_policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          "arn:aws:s3:::${local.photos_bucket_name}",
          "arn:aws:s3:::${local.photos_bucket_name}/*"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_s3_attach" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = aws_iam_policy.lambda_s3_policy.arn
}

resource "aws_iam_policy" "lambda_dynamodb_policy" {
  name = "gazeebo_lambda_dynamodb_policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:DeleteItem",
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:Scan"
        ]
        Resource = "arn:aws:dynamodb:${var.aws_region}:${local.account_id}:table/${var.dynamodb_table_name}"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_dynamodb_attach" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = aws_iam_policy.lambda_dynamodb_policy.arn
}

# ==========================================
# 6. LAMBDA FUNCTION SOURCE & DEPLOYMENT
# ==========================================
data "archive_file" "lambda_zip" {
  type        = "zip"
  output_path = "${path.module}/lambda.zip"
  source_content = <<EOF
const { S3Client, DeleteObjectCommand, ListObjectsV2Command, PutObjectCommand, GetObjectCommand } = require("@aws-sdk/client-s3");
const { getSignedUrl } = require("@aws-sdk/s3-request-presigner");
const { DynamoDBClient } = require("@aws-sdk/client-dynamodb");
const { DynamoDBDocumentClient, DeleteCommand } = require("@aws-sdk/lib-dynamodb");

const s3 = new S3Client({ region: process.env.AWS_REGION || "us-west-1" });
const ddbClient = new DynamoDBClient({ region: process.env.AWS_REGION || "us-west-1" });
const dynamodb = DynamoDBDocumentClient.from(ddbClient);

const TABLE_NAME = process.env.TABLE_NAME || "GazeeboPortalData";

const corsHeaders = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "Content-Type,Authorization",
    "Access-Control-Allow-Methods": "OPTIONS,POST,GET,DELETE"
};

exports.handler = async (event) => {
    console.log("Event:", JSON.stringify(event));
    
    const httpMethod = event.requestContext?.http?.method || event.httpMethod;
    if (httpMethod === 'OPTIONS') {
        return { statusCode: 200, headers: corsHeaders, body: "" };
    }
    
    try {
        const bucketName = process.env.BUCKET_NAME;
        if (!bucketName) throw new Error("BUCKET_NAME env var not set.");

        if (httpMethod === 'GET') {
            const command = new ListObjectsV2Command({ Bucket: bucketName, Prefix: 'photos/' });
            const response = await s3.send(command);
            const photos = [];

            if (response.Contents) {
                for (const item of response.Contents) {
                    if (item.Key.endsWith('/') || item.Size === 0) continue;
                    const getCommand = new GetObjectCommand({ Bucket: bucketName, Key: item.Key });
                    const viewUrl = await getSignedUrl(s3, getCommand, { expiresIn: 3600 });
                    photos.push({ key: item.Key, url: viewUrl, lastModified: item.LastModified });
                }
            }
            return { statusCode: 200, headers: corsHeaders, body: JSON.stringify(photos) };
        }

        if (httpMethod === 'POST') {
            const body = typeof event.body === 'string' ? JSON.parse(event.body || "{}") : (event.body || {});
            const filename = body.filename;
            const filetype = body.filetype || 'application/octet-stream';

            if (!filename) {
                return { statusCode: 400, headers: corsHeaders, body: JSON.stringify({ error: "Missing filename" }) };
            }

            const objectKey = `photos/$${Date.now()}-$${filename}`;
            const putCommand = new PutObjectCommand({ Bucket: bucketName, Key: objectKey, ContentType: filetype });
            const uploadUrl = await getSignedUrl(s3, putCommand, { expiresIn: 300 });

            return { statusCode: 200, headers: corsHeaders, body: JSON.stringify({ uploadUrl, fileKey: objectKey }) };
        }

        if (httpMethod === 'DELETE') {
            const photoKey = event.queryStringParameters?.key || event.queryStringParameters?.fileKey;
            if (!photoKey) {
                return { statusCode: 400, headers: corsHeaders, body: JSON.stringify({ error: "Missing key parameter" }) };
            }

            await s3.send(new DeleteObjectCommand({ Bucket: bucketName, Key: photoKey }));
            try {
                await dynamodb.send(new DeleteCommand({ TableName: TABLE_NAME, Key: { id: photoKey } }));
            } catch (dbErr) {
                console.warn("DynamoDB delete warning:", dbErr);
            }

            return { statusCode: 200, headers: corsHeaders, body: JSON.stringify({ message: "Photo deleted", key: photoKey }) };
        }

        return { statusCode: 404, headers: corsHeaders, body: JSON.stringify({ error: `Method $${httpMethod} unsupported.` }) };
    } catch (error) {
        console.error("Error:", error);
        return { statusCode: 500, headers: corsHeaders, body: JSON.stringify({ error: error.message }) };
    }
};
EOF
  source_file_name = "index.js"
}

resource "aws_lambda_function" "api_lambda" {
  filename         = data.archive_file.lambda_zip.output_path
  function_name    = "gazeebo_api_handler"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "index.handler"
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  runtime          = "nodejs20.x"
  timeout          = 15

  environment {
    variables = {
      BUCKET_NAME = local.photos_bucket_name
      TABLE_NAME  = var.dynamodb_table_name
    }
  }
}

# ==========================================
# 7. API GATEWAY (HTTP API) WITH COGNITO AUTH
# ==========================================
resource "aws_apigatewayv2_api" "http_api" {
  name          = "gazeebo-http-api"
  protocol_type = "HTTP"
  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["OPTIONS", "POST", "GET", "DELETE"]
    allow_headers = ["Content-Type", "Authorization"]
    max_age       = 300
  }
}

# JWT Authorizer for Cognito
resource "aws_apigatewayv2_authorizer" "cognito" {
  api_id           = aws_apigatewayv2_api.http_api.id
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]
  name             = "cognito-authorizer"

  jwt_configuration {
    audience = [aws_cognito_user_pool_client.client.id]
    issuer   = "https://${aws_cognito_user_pool.pool.endpoint}"
  }
}

resource "aws_apigatewayv2_integration" "lambda_integration" {
  api_id                 = aws_apigatewayv2_api.http_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.api_lambda.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "default_route" {
  api_id             = aws_apigatewayv2_api.http_api.id
  route_key          = "$default"
  target             = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

resource "aws_apigatewayv2_stage" "default_stage" {
  api_id      = aws_apigatewayv2_api.http_api.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "api_gateway_invoke" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api_lambda.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http_api.execution_arn}/*/*"
}
