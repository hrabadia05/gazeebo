terraform {
  backend "s3" {
    bucket         = "gazeebo-private-photos-501970550518"
    key            = "terraform/state/gazeebo.tfstate"
    region         = "us-west-1"
    dynamodb_table = "GazeeboPortalData"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region
}
