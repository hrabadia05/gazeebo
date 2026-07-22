# ==========================================
# 1. AWS ACCOUNT ID DATA SOURCE
# ==========================================
data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
}

# ==========================================
# 2. LAMBDA IAM ROLE & POLICIES
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
          "s3:ListBucket"
        ]
        Resource = [
          "arn:aws:s3:::gazeebo-private-photos-${local.account_id}",
          "arn:aws:s3:::gazeebo-private-photos-${local.account_id}/*"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_s3_attach" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = aws_iam_policy.lambda_s3_policy.arn
}

# ==========================================
# 3. LAMBDA FUNCTION SOURCE & DEPLOYMENT
# ==========================================
data "archive_file" "lambda_zip" {
  type        = "zip"
  output_path = "${path.module}/lambda.zip"
  source_content = <<EOF
const { S3Client, PutObjectCommand, ListObjectsV2Command, GetObjectCommand } = require("@aws-sdk/client-s3");
const { getSignedUrl } = require("@aws-sdk/s3-request-presigner");

const s3 = new S3Client({ region: process.env.AWS_REGION || "us-west-1" });

const corsHeaders = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "Content-Type,Authorization",
    "Access-Control-Allow-Methods": "OPTIONS,POST,GET"
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

        // Handle GET requests: List vault photos and generate view URLs
        if (httpMethod === 'GET') {
            const command = new ListObjectsV2Command({
                Bucket: bucketName,
                Prefix: 'uploads/'
            });
            
            const response = await s3.send(command);
            const photos = [];

            if (response.Contents) {
                for (const item of response.Contents) {
                    const getCommand = new GetObjectCommand({
                        Bucket: bucketName,
                        Key: item.Key
                    });
                    const viewUrl = await getSignedUrl(s3, getCommand, { expiresIn: 900 });
                    photos.push({ key: item.Key, url: viewUrl, lastModified: item.LastModified });
                }
            }

            return {
                statusCode: 200,
                headers: corsHeaders,
                body: JSON.stringify({ photos }),
            };
        }

        // Handle POST requests: Generate pre-signed upload URL
        const body = typeof event.body === 'string' ? JSON.parse(event.body || "{}") : (event.body || {});
        const filename = body.filename;
        const filetype = body.filetype;

        if (!filename || !filetype) {
            return {
                statusCode: 400,
                headers: corsHeaders,
                body: JSON.stringify({ error: "Missing filename or filetype in request body" }),
            };
        }

        const objectKey = `uploads/${Date.now()}-${filename}`;
        const putCommand = new PutObjectCommand({
            Bucket: bucketName,
            Key: objectKey,
            ContentType: filetype,
        });

        const uploadUrl = await getSignedUrl(s3, putCommand, { expiresIn: 300 });

        return {
            statusCode: 200,
            headers: corsHeaders,
            body: JSON.stringify({ uploadUrl }),
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
  runtime          = "nodejs18.x"
  timeout          = 15

  environment {
    variables = {
      BUCKET_NAME = "gazeebo-private-photos-${local.account_id}"
    }
  }
}

# ==========================================
# 4. API GATEWAY (HTTP API)
# ==========================================
resource "aws_apigatewayv2_api" "http_api" {
  name          = "gazeebo-http-api"
  protocol_type = "HTTP"
  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["OPTIONS", "POST", "GET"]
    allow_headers = ["Content-Type", "Authorization"]
  }
}

resource "aws_apigatewayv2_integration" "lambda_integration" {
  api_id           = aws_apigatewayv2_api.http_api.id
  integration_type = "AWS_PROXY"
  integration_uri  = aws_lambda_function.api_lambda.invoke_arn
}

resource "aws_apigatewayv2_route" "proxy_route" {
  api_id    = aws_apigatewayv2_api.http_api.id
  route_key = "ANY /{proxy+}"
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
