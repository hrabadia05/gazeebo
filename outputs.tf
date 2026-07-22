output "cognito_user_pool_id" {
  description = "The ID of the Cognito User Pool for authentication"
  value       = aws_cognito_user_pool.pool.id
}

output "cognito_client_id" {
  description = "The App Client ID for your frontend JavaScript SDK"
  value       = aws_cognito_user_pool_client.client.id
}

output "cloudfront_domain_url" {
  description = "The secure HTTPS URL of your CloudFront distribution"
  value       = "https://${aws_cloudfront_distribution.cdn.domain_name}"
}

output "photos_bucket_name" {
  description = "The name of the private S3 bucket storing photos"
  value       = aws_s3_bucket.photos_bucket.id
}

output "website_bucket_name" {
  description = "The name of the S3 bucket hosting frontend files"
  value       = aws_s3_bucket.website_bucket.id
}
