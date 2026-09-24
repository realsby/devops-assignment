# Apply order (chicken-and-egg: Lambda needs an image to exist before it
# can be created; the deploy role needs the Lambda functions to exist
# before it can be scoped to them):
#
#   1. infra/terraform/bootstrap applied first (separate state) — creates
#      the S3 backend this module uses, and the GitHub OIDC provider.
#   2. terraform apply -target=aws_ecr_repository.portal \
#                       -target=aws_ecr_repository.notifier
#      Creates just the two ECR repos. Nothing referencing var.image_tag
#      is touched yet, so the placeholder default below is fine here.
#   3. Build and push both images, outside Terraform:
#        docker build --platform linux/amd64 -t <repo_url>:<git_sha> .
#        docker push <repo_url>:<git_sha>
#   4. terraform apply -var image_tag=<git_sha>
#      Full apply: Neon role/database, app DB roles, SSM params, both
#      Lambda functions (now resolvable), the scheduler, the receipts
#      bucket, and the GitHub deploy role.
#
# CI deploys by pushing new images and calling UpdateFunctionCode
# directly — it does not run terraform apply. image_tag/ignore_changes
# on image_uri (see lambda_portal.tf / lambda_notifier.tf) exists so a
# later `terraform apply` doesn't fight that and roll a Lambda back to
# whatever git_sha was last planned here.
variable "image_tag" {
  type        = string
  description = "Git SHA tag of the images already pushed to ECR. Placeholder default only works for the ECR-only -target apply in step 2 above."
  default     = "bootstrap"
}

variable "aws_region" {
  type    = string
  default = "eu-central-1"
}

variable "github_oidc_sub_prefix" {
  type        = string
  description = "OIDC sub prefix GitHub issues for the repo (immutable form, owner@id/repo@id)."
  default     = "repo:realsby@1173351/devops-assignment@1385494367"
}


variable "neon_project_id" {
  type    = string
  default = "frosty-tree-52704700"
}

variable "neon_org_id" {
  type    = string
  default = "org-little-feather-38495886"
}

variable "alert_email" {
  type        = string
  description = "Where alarm ALARM/OK notifications go. SNS will send a subscription-confirmation email here on first apply that has to be clicked before anything actually arrives."
  default     = "realsby@gmail.com"
}
