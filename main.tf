data "aws_partition" "current" {}

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

locals {
  project_name        = "${var.codecommit_repo_name}-releases"
  log_group_arn       = "arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${local.project_name}"
  codecommit_repo_arn = "arn:aws:codecommit:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:${var.codecommit_repo_name}"
  codecommit_repo_url = "https://git-codecommit.${data.aws_region.current.name}.amazonaws.com/v1/repos/${var.codecommit_repo_name}"
}

# Codebuild resources

data "aws_iam_policy_document" "codebuild_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "codebuild" {
  statement {
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]

    resources = [
      "${local.log_group_arn}",
      "${local.log_group_arn}:*",
    ]
  }

  statement {
    actions = [
      "codecommit:GitPull",
    ]

    resources = ["${local.codecommit_repo_arn}"]
  }

  statement {
    actions = [
      "codecommit:GitPush",
    ]

    resources = ["${local.codecommit_repo_arn}"]

    condition = {
      test     = "StringLikeIfExists"
      variable = "codecommit:References"
      values   = ["refs/tags/*"]
    }
  }
}

resource "aws_iam_role" "codebuild" {
  name = "codebuild-${local.project_name}-service-role"

  assume_role_policy = "${data.aws_iam_policy_document.codebuild_assume_role.json}"
}

resource "aws_iam_role_policy" "codebuild" {
  name   = "codebuild-${local.project_name}"
  role   = "${aws_iam_role.codebuild.id}"
  policy = "${data.aws_iam_policy_document.codebuild.json}"
}

resource "aws_codebuild_project" "this" {
  name         = "${local.project_name}"
  description  = "Tag target repo when version is incremented in default branch"
  service_role = "${aws_iam_role.codebuild.arn}"

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/nodejs:8.11.0"
    type         = "LINUX_CONTAINER"
  }

  source {
    type      = "CODECOMMIT"
    location  = "${local.codecommit_repo_url}"
    buildspec = "${local.buildspec}"
  }
}

locals {
  buildspec = <<-BUILDSPEC
    version: 0.2
    phases:
      install:
        commands:
          - npm install -g semver
          - which semver
      pre_build:
        commands:
          - PRIOR_VERSION=$(eval "${var.prior_version_command}")
          - RELEASE_VERSION=$(eval "${var.release_version_command}")
          - echo PRIOR_VERSION="$PRIOR_VERSION"
          - echo RELEASE_VERSION="$RELEASE_VERSION"
          - git branch
          - git rev-parse HEAD
      build:
        commands:
          - |
            if [ $(semver -r '<='"$PRIOR_VERSION" "$RELEASE_VERSION" > /dev/null)$? -eq 0 ]
            then
              echo "Version has not incremented, skipping release"
            elif [ $(semver -r '>'"$PRIOR_VERSION" "$RELEASE_VERSION" > /dev/null)$? -eq 0 ]
            then
              echo "Releasing version $RELEASE_VERSION"
              git config credential.helper '!aws codecommit credential-helper $@' || exit 1
              git config credential.UseHttpPath true || exit 1
              git tag "$RELEASE_VERSION" || exit 1
              git push --tags || exit 1
            else
              echo "Unknown error occured" && exit 1
            fi
    BUILDSPEC
}

# Cloudwatch Event Resources

data "aws_iam_policy_document" "events_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "events" {
  statement {
    actions = [
      "codebuild:StartBuild",
    ]

    resources = ["${aws_codebuild_project.this.id}"]
  }
}

resource "aws_iam_role" "events" {
  name = "cloudwatch-events-${local.project_name}-service-role"

  assume_role_policy = "${data.aws_iam_policy_document.events_assume_role.json}"
}

resource "aws_iam_role_policy" "events" {
  name   = "cloudwatch-events-${local.project_name}"
  role   = "${aws_iam_role.events.id}"
  policy = "${data.aws_iam_policy_document.events.json}"
}

resource "aws_cloudwatch_event_rule" "this" {
  name        = "${local.project_name}"
  description = "Tag target repo when version is incremented in default branch"

  event_pattern = <<-PATTERN
    {
      "detail-type": ["CodeCommit Repository State Change"],
      "source": ["aws.codecommit"],
      "detail": {
        "event": ["referenceUpdated"],
        "repositoryName": ["${var.codecommit_repo_name}"],
        "referenceType": ["branch"],
        "referenceName": ["${var.default_branch}"]
      }
    }
    PATTERN
}

resource "aws_cloudwatch_event_target" "this" {
  rule     = "${aws_cloudwatch_event_rule.this.name}"
  arn      = "${aws_codebuild_project.this.id}"
  role_arn = "${aws_iam_role.events.arn}"
}