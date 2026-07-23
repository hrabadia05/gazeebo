# ==========================================
# 1. AWS ACCOUNT ID DATA SOURCE & LOCALS
# ==========================================
data "aws_caller_identity" "current" {}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  bucket_name = "gazeebo-private-photos-${local.account_id}"
}

# ==========================================
# 2. S3 BUCKET & CORS CONFIGURATION
# ==========================================
resource "aws_s3_bucket" "photos_bucket" {
  bucket        = local.bucket_name
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

# Block all public access by default (Security Best Practice)
resource "aws_s3_bucket_public_access_block" "photos_bucket_block" {
  bucket                  = aws_s3_bucket.photos_bucket.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ==========================================
# 3. LAMBDA IAM ROLE & POLICIES
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
          "arn:aws:s3:::${local.bucket_name}",
          "arn:aws:s3:::${local.bucket_name}/*"
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
        Resource = "arn:aws:dynamodb:us-west-1:${local.account_id}:table/GazeeboPortalData"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_dynamodb_attach" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = aws_iam_policy.lambda_dynamodb_policy.arn
}

# ==========================================
# 4. LAMBDA FUNCTION SOURCE & DEPLOYMENT
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

const TABLE_NAME = "GazeeboPortalData";

const corsHeaders = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "Content-Type,Authorization",
    "Access-Control-Allow-Methods": "OPTIONS,POST,GET,DELETE"
};

exports.handler = async (event) => {
    console.log("Event:", JSON.stringify(event));
    
    const httpMethod = event.requestContext?.http?.method || event.httpMethod;
    if (httpMethod === 'OPTIONS') {
        return {
            statusCode: 200,
            headers: corsHeaders,
            body: ""
        };
    }
    
    try {
        const bucketName = process.env.BUCKET_NAME;
        if (!bucketName) {
            throw new Error("BUCKET_NAME environment variable is not set on Lambda function.");
        }

        // --- GET ROUTE: List photos & generate view URLs ---
        if (httpMethod === 'GET') {
            const command = new ListObjectsV2Command({
                Bucket: bucketName,
                Prefix: 'photos/'
            });
            
            const response = await s3.send(command);
            const photos = [];

            if (response.Contents) {
                for (const item of response.Contents) {
                    if (item.Key.endsWith('/') || item.Size === 0) continue;

                    const getCommand = new GetObjectCommand({
                        Bucket: bucketName,
                        Key: item.Key
                    });
                    const viewUrl = await getSignedUrl(s3, getCommand, { expiresIn: 3600 });
                    photos.push({ key: item.Key, url: viewUrl, lastModified: item.LastModified });
                }
            }

            return {
                statusCode: 200,
                headers: corsHeaders,
                body: JSON.stringify(photos),
            };
        }

        // --- POST ROUTE: Generate pre-signed upload URL ---
        if (httpMethod === 'POST') {
            const body = typeof event.body === 'string' ? JSON.parse(event.body || "{}") : (event.body || {});
            const filename = body.filename;
            const filetype = body.filetype || 'application/octet-stream';

            if (!filename) {
                return {
                    statusCode: 400,
                    headers: corsHeaders,
                    body: JSON.stringify({ error: "Missing filename in request body" }),
                };
            }

            const objectKey = `photos/$${Date.now()}-$${filename}`;
            const putCommand = new PutObjectCommand({
                Bucket: bucketName,
                Key: objectKey,
                ContentType: filetype,
            });

            const uploadUrl = await getSignedUrl(s3, putCommand, { 
                expiresIn: 300
            });

            return {
                statusCode: 200,
                headers: corsHeaders,
                body: JSON.stringify({ uploadUrl, fileKey: objectKey }),
            };
        }

        // --- DELETE ROUTE: Remove Photo from S3 & DynamoDB ---
        if (httpMethod === 'DELETE') {
            const photoKey = event.queryStringParameters?.key || event.queryStringParameters?.fileKey;
            
            if (!photoKey) {
                return {
                    statusCode: 400,
                    headers: corsHeaders,
                    body: JSON.stringify({ error: "Missing 'key' query parameter for deletion." })
                };
            }

            await s3.send(new DeleteObjectCommand({
                Bucket: bucketName,
                Key: photoKey
            }));

            try {
                await dynamodb.send(new DeleteCommand({
                    TableName: TABLE_NAME,
                    Key: { id: photoKey }
                }));
            } catch (dbErr) {
                console.warn("DynamoDB item delete warning:", dbErr);
            }

            return {
                statusCode: 200,
                headers: corsHeaders,
                body: JSON.stringify({ message: "Photo deleted successfully", key: photoKey })
            };
        }

        return {
            statusCode: 404,
            headers: corsHeaders,
            body: JSON.stringify({ error: `Route or method $${httpMethod} not supported.` })
        };

    } catch (error) {
        console.error("Error:", error);
        return {
            statusCode: 500,
            headers: corsHeaders,
            body: JSON.stringify({ error: error.message }),
        };
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
      BUCKET_NAME = local.bucket_name
    }
  }
}

# ==========================================
# 5. API GATEWAY (HTTP API)
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

resource "aws_apigatewayv2_integration" "lambda_integration" {
  api_id                 = aws_apigatewayv2_api.http_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.api_lambda.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "default_route" {
  api_id    = aws_apigatewayv2_api.http_api.id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
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

# ==========================================
# 6. OUTPUTS
# ==========================================
output "api_endpoint" {
  description = "HTTP API Gateway endpoint URL"
  value       = aws_apigatewayv2_stage.default_stage.invoke_url
}

output "s3_bucket_name" {
  description = "Name of the S3 bucket"
  value       = aws_s3_bucket.photos_bucket.id
}
