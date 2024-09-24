provider "aws" {
  region = "us-east-1"
}

variable "apiGatewayId" {
  description = "The ID of the API Gateway REST API you want the authorizer connected to"
  type        = string
}

variable "policyStoreId" {
  description = "The ID of the AVP policy store the authorizer is connected to"
  type        = string
}

variable "tokenType" {
  description = "Whether the token is accessToken or identityToken"
  type        = string
  default     = "accessToken"
  validation {
    condition     = contains(["accessToken", "identityToken"], var.tokenType)
    error_message = "Invalid token type"
  }
}

variable "endpointOverride" {
  description = "Internal use only"
  type        = string
  default     = ""
}

variable "namespace" {
  description = "Schema namespace"
  type        = string
}

variable "apiStage" {
  description = "Stage to deploy once the authorizer is attached to the APIs"
  type        = string
  default     = ""
}

variable "shouldAttachAuthorizer" {
  description = "Whether authorizer should be attached or not"
  type        = string
  default     = "false"
  validation {
    condition     = contains(["true", "false"], var.shouldAttachAuthorizer)
    error_message = "Value must be either 'true' or 'false'"
  }
}

resource "aws_iam_role" "avp_authorizer_lambda_role" {
  name = "AVPAuthorizerLambdaServiceRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })

  managed_policy_arns = [
    "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
  ]
}

resource "aws_iam_policy" "avp_authorizer_lambda_policy" {
  name        = "AVPAuthorizerLambdaServiceRoleDefaultPolicy"
  description = "Policy for AVP Authorizer Lambda Role"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "verifiedpermissions:isAuthorizedWithToken",
          "logs:PutLogEvents"
        ]
        Effect   = "Allow"
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "attach_avp_authorizer_lambda_policy" {
  policy_arn = aws_iam_policy.avp_authorizer_lambda_policy.arn
  role       = aws_iam_role.avp_authorizer_lambda_role.name
}

resource "aws_lambda_function" "avp_authorizer_lambda" {
  function_name = "AVPAuthorizerLambda-${var.policyStoreId}"

  handler = "index.handler"
  runtime = "nodejs20.x"
  
  environment = {
    POLICY_STORE_ID = var.policyStoreId
    TOKEN_TYPE      = var.tokenType
    NAMESPACE       = var.namespace
    ENDPOINT        = var.endpointOverride
  }

  # Include your Lambda function code here
  code {
    zip_file = <<EOF
const { VerifiedPermissions } = require('@aws-sdk/client-verifiedpermissions');
const policyStoreId = process.env.POLICY_STORE_ID;
const namespace = process.env.NAMESPACE;
const tokenType = process.env.TOKEN_TYPE;
const resourceType = `${namespace}::Application`;
const resourceId = namespace;
const actionType = `${namespace}::Action`;

const verifiedpermissions = !!process.env.ENDPOINT
  ? new VerifiedPermissions({
    endpoint: \`https://\${process.env.ENDPOINT}ford.\${process.env.AWS_REGION}.amazonaws.com\`,
  })
  : new VerifiedPermissions();

// Your Lambda handler code goes here...
EOF
  }

  role = aws_iam_role.avp_authorizer_lambda_role.arn

  depends_on = [aws_iam_policy.avp_authorizer_lambda_policy]
}

resource "aws_api_gateway_authorizer" "avp_authorizer" {
  name                          = "AVPAuthorizer-${var.policyStoreId}"
  rest_api_id                  = var.apiGatewayId
  authorizer_uri               = "arn:aws:apigateway:${data.aws_region.current.name}:lambda:path/2015-03-31/functions/${aws_lambda_function.avp_authorizer_lambda.arn}/invocations"
  identity_source              = "method.request.header.Authorization,context.httpMethod,context.path"
  authorizer_result_ttl_in_seconds = 120
  type                          = "REQUEST"
}

resource "aws_lambda_permission" "allow_api_gateway" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.avp_authorizer_lambda.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "arn:aws:execute-api:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:${var.apiGatewayId}/authorizers/${aws_api_gateway_authorizer.avp_authorizer.id}"
}

resource "aws_iam_role" "api_gateway_attacher_role" {
  count = var.shouldAttachAuthorizer == "true" ? 1 : 0

  name = "ApiGatewayAttacherFnServiceRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })

  managed_policy_arns = [
    "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
  ]
}

resource "aws_lambda_function" "api_gateway_attacher" {
  count = var.shouldAttachAuthorizer == "true" ? 1 : 0

  function_name = "AVP-ApiGatewayAttacherFn-${var.policyStoreId}"

  handler = "index.handler"
  runtime = "nodejs20.x"
  
  environment = {
    API_GATEWAY_ID   = var.apiGatewayId
    API_GATEWAY_STAGE = var.apiStage
    AUTHORIZER_ID    = aws_api_gateway_authorizer.avp_authorizer.id
  }

  # Include your attacher Lambda function code here
  code {
    zip_file = <<EOF
const { APIGatewayClient, UpdateMethodCommand, CreateDeploymentCommand, GetResourcesCommand } = require('@aws-sdk/client-api-gateway');
const apigateway = new APIGatewayClient();

// Your Lambda handler code goes here...
EOF
  }

  role = aws_iam_role.api_gateway_attacher_role[0].arn
  timeout = 600

  depends_on = [aws_iam_role.api_gateway_attacher_role]
}

resource "aws_cloudformation_stack" "api_gateway_attacher" {
  count = var.shouldAttachAuthorizer == "true" ? 1 : 0

  template_body = <<EOF
Resources:
  ApiGatewayAttacher:
    Type: AWS::Lambda::Function
    Properties:
      FunctionName: !Sub "AVP-ApiGatewayAttacherFn-${policyStoreId}"
      Handler: index.handler
      Role: !GetAtt ApiGatewayAttacherFnServiceRole.Arn
      Runtime: nodejs20.x
      Environment:
        API_GATEWAY_ID: ${var.apiGatewayId}
        API_GATEWAY_STAGE: ${var.apiStage}
        AUTHORIZER_ID: !GetAtt AVPAuthorizerConfiguration.AuthorizerId
EOF
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

output "authorizer_id" {
  value = aws_api_gateway_authorizer.avp_authorizer.id
}

output "authorizer_lambda_function" {
  value = aws_lambda_function.avp_authorizer_lambda.arn
}
================================================================
variable "tags" {
  description = "Default tags to apply to all resources."
  type        = map(any)
}

# All variables as it would be defined in the .tfvars file.

tags = {
  archuuid = "2b2b3216-3605-4665-86e8-e0af2ffa5186"
  env      = "Development"
}


resource "aws_verifiedpermissions_policy_store" "example" {

  # Code not auto-generated by Brainboard
  name = "example-policy-store"
}

resource "aws_verifiedpermissions_policy" "apigateway_policy" {
  policy_store_id = aws_verifiedpermissions_policy_store.example.id

  # Code not auto-generated by Brainboard
  name            = "apigateway-policy"
  policy_document = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "execute-api:Invoke",
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "cognito-identity.amazonaws.com:aud": "${aws_cognito_user_pool.example.id}"
        }
      }
    }
  ]
}
POLICY
}

resource "aws_verifiedpermissions_policy" "cognito_policy" {
  policy_store_id = aws_verifiedpermissions_policy_store.example.id

  # Code not auto-generated by Brainboard
  name            = "cognito-policy"
  policy_document = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "cognito-idp:*",
      "Resource": "${aws_cognito_user_pool.example.arn}"
    }
  ]
}
POLICY
}

resource "aws_cognito_user_pool" "example" {
  name = "example-user-pool"
}

resource "aws_api_gateway_rest_api" "example" {
  name = "example-api"
}

resource "aws_api_gateway_method" "example" {
  rest_api_id   = aws_api_gateway_rest_api.example.id
  resource_id   = aws_api_gateway_rest_api.example.root_resource_id
  http_method   = "GET"
  authorizer_id = aws_cognito_user_pool.example.id
  authorization = "COGNITO_USER_POOLS"
}
