# GitHub Actions OIDC trust anchor. One per account — created once here,
# looked up (not re-created) from infra/terraform/prod via a data source,
# since the actual deploy role needs prod-only resource ARNs (ECR repos,
# Lambda functions, SSM params) to scope its permissions to.
#
# GUESSED: the thumbprint. AWS now validates the full certificate chain
# for this provider rather than matching the leaf thumbprint, so in
# practice any well-formed value in this list is accepted — but I have
# not verified this specific value against GitHub's current intermediate
# CA. Worth a quick check before relying on it.
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}
