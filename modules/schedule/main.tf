locals {
  stage             = "schedule"
  stage_description = "Execute a job/buildspec on a schedule"
}

module "handler" {
  source = "../_internal/handler"

  handler           = "schedule_handler"
  stage             = "${local.stage}"
  stage_description = "${local.stage_description}"
  repo_name         = "${var.repo_name}"
  project_arn       = "${module.runner.codebuild_project_arn}"
}

module "runner" {
  source = "../_internal/runner"

  stage                 = "${local.stage}"
  stage_description     = "${local.stage_description}"
  repo_name             = "${var.repo_name}"
  buildspec             = "${var.buildspec}"
  artifacts             = "${var.artifacts}"
  environment           = "${var.environment}"
  environment_variables = "${var.environment_variables}"
  policy_override       = "${var.policy_override}"
  policy_arns           = "${var.policy_arns}"
}

module "trigger" {
  source = "../_internal/trigger"

  stage               = "${local.stage}"
  stage_description   = "${local.stage_description}"
  target_arn          = "${module.handler.function_arn}"
  repo_name           = "${var.repo_name}"
  schedule_expression = "${var.schedule_expression}"
}

resource "aws_lambda_permission" "trigger" {
  action        = "lambda:InvokeFunction"
  function_name = "${module.handler.function_name}"
  principal     = "events.amazonaws.com"
  source_arn    = "${module.trigger.events_rule_arn}"
}
