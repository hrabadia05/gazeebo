# ==========================================
# IAM ROLE & POLICIES FOR LAMBDA
# ==========================================
resource "aws_iam_role" "lambda_exec" {
  name = "gazeebo-lambda-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_policy" "lambda_s3_dynamo_policy" {
  name = "gazeebo-lambda-s3-dynamo-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject"
        ]
        Resource = "${aws_s3_bucket.photos_bucket.arn}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:GetItem",
          "dynamodb:Scan",
          "dynamodb:Query"
        ]
        Resource = aws_dynamodb_table.gazeebo_db.arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_custom_attachment" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = aws_iam_policy.lambda_s3_dynamo_policy.arn
}

# ==========================================
# AWS LAMBDA FUNCTION (Placeholder Code)
# ==========================================
data "archive_file" "lambda_dummy" {
  type        = "zip"
  output_path = "${path.module}/lambda_function.zip"
  source {
    content  = <<EOF
exports.handler = async (event) => {
    return {
        statusCode: 200,
        body: JSON.stringify({ message: "Hello from Gazeebo Backend!" }),
    };
};
EOF
    filename = "index.js"
  }
}

resource "aws_lambda_function" "api_handler" {
  filename         = "${path.module}/lambda_function.zip"
  function_name    = "gazeebo-api-handler"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "index.handler"
  runtime          = "nodejs20.x"
  source_code_hash = data.archive_file.lambda_dummy.output_base64sha256
}

# ==========================================
# AMAZON API GATEWAY (HTTP API)
# ==========================================
resource "aws_apigatewayv2_api" "http_api" {
  name          = "gazeebo-http-api"
  protocol_type = "HTTP"
  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["GET", "POST", "OPTIONS"]
    allow_headers = ["content-type", "authorization"]
  }
}

resource "aws_apigatewayv2_integration" "lambda_integration" {
  api_id           = aws_apigatewayv2_api.http_api.id
  integration_type = "AWS_PROXY"
  integration_uri  = aws_lambda_function.api_handler.invoke_arn
}

resource "aws_apigatewayv2_route" "default_route" {
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
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api_handler.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http_api.execution_arn}/*/*"
}

# ==========================================
# OUTPUTS FOR BACKEND ENDPOINT
# ==========================================
output "api_gateway_url" {
  description = "The HTTP endpoint URL for your serverless backend"
  value       = aws_apigatewayv2_api.http_api.api_endpoint
}
