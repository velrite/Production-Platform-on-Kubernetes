terraform {
  backend "s3" {
    bucket       = "tfstate-681117450689-platform"
    key          = "platform/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}
