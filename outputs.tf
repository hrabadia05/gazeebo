# ==========================================
# GAZEEBO INFRASTRUCTURE OUTPUTS
# ==========================================

output "cloudfront_domain_url" {
  description = "Access your application at this HTTPS URL in your browser."
  value       = "https://${aws_cloudfront_distribution.cdn.domain_name}"
}

output "api_endpoint" {
  description = "Paste into photos.html (around Line 85 -> apiGatewayUrl)"
  value       = aws_apigatewayv2_stage.default_stage.invoke_url
}

output "cognito_user_pool_id" {
  description = "Paste into index.html (around Line 44 -> UserPoolId) AND photos.html (around Line 83 -> userPoolId)"
  value       = aws_cognito_user_pool.pool.id
}

output "cognito_client_id" {
  description = "Paste into index.html (around Line 45 -> ClientId) AND photos.html (around Line 84 -> clientId)"
  value       = aws_cognito_user_pool_client.client.id
}

output "website_bucket_name" {
  description = "Upload index.html and photos.html directly to this S3 bucket."
  value       = aws_s3_bucket.website_bucket.id
}

output "photos_bucket_name" {
  description = "The private S3 bucket storing uploaded photo assets."
  value       = aws_s3_bucket.photos_bucket.id
}
