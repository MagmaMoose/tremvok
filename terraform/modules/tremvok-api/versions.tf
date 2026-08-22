terraform {
  # 1.9 for the `templatestring` / early-variable-validation era the rest of the estate is on.
  # OpenTofu satisfies this; the last BUSL-free Terraform (1.5.7) does not.
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
