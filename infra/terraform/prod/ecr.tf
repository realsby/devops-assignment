resource "aws_ecr_repository" "portal" {
  name                 = "wellis-status/portal"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_repository" "notifier" {
  name                 = "wellis-status/notifier"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

locals {
  ecr_keep_last_10 = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

resource "aws_ecr_lifecycle_policy" "portal" {
  repository = aws_ecr_repository.portal.name
  policy     = local.ecr_keep_last_10
}

resource "aws_ecr_lifecycle_policy" "notifier" {
  repository = aws_ecr_repository.notifier.name
  policy     = local.ecr_keep_last_10
}
