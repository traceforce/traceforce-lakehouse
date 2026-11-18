#!/usr/bin/env bash
# The stub left at terraform/aws after the AWS (Athena) module moved to terraform/aws/athena: a
# configuration that still points at the old path must stop with the move message, never with
# "Unsupported argument" / "Unsupported attribute". It must already stop at validate, before
# Terraform computes changes, so a configuration with existing state never sees its resources
# listed as "will be destroyed". Needs no AWS credentials (the stub uses no AWS resources), only
# network for terraform init to download the aws provider. Also checks that terraform/aws/athena
# and examples/aws/athena still validate.
#
#   tests/terraform/test_aws_moved_stub.sh
set -u
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fails=0

# Root configurations as customers wrote them for the old path: source + inputs (+ an output read).
root() { # dir module-body extra-root-hcl
  mkdir -p "$WORK/$1"
  cat > "$WORK/$1/main.tf" <<EOF
module "traceforce_lakehouse" {
  source = "$REPO/terraform/aws"
$2
}
$3
EOF
}

root required_only 'logs_bucket = "acme-traceforce-logs"' ''
root reads_output  'logs_bucket = "acme-traceforce-logs"
  logs_prefix = "traceforce"' 'output "query_policy_json" { value = module.traceforce_lakehouse.query_policy_json }'
root all_inputs    'logs_bucket              = "acme-traceforce-logs"
  logs_prefix              = "traceforce"
  logs_kms_key_arn         = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000000"
  alarm_sns_topic_arn      = "arn:aws:sns:us-east-1:123456789012:alerts"
  create_glue_integration  = false
  query_trusted_principals = ["arn:aws:iam::123456789012:root"]' 'output "role" { value = module.traceforce_lakehouse.query_role_arn }'

# logs_bucket only known after apply: the guard must not be deferred to apply.
root unknown_input 'logs_bucket = terraform_data.bucket.output' 'resource "terraform_data" "bucket" { input = "acme-traceforce-logs" }'

for c in required_only reads_output all_inputs unknown_input; do
  d="$WORK/$c"
  if ! out="$(terraform -chdir="$d" init -backend=false -input=false -no-color 2>&1)"; then
    echo "FAIL  $c: init failed: $out"; fails=$((fails + 1)); continue
  fi
  # validate must already fail with the message: that's before Terraform computes any changes, so
  # a configuration with existing state never sees its resources listed as "will be destroyed".
  vout="$(terraform -chdir="$d" validate -no-color 2>&1)"; vcode=$?
  if [[ $vcode -ne 0 && "$vout" == *"moved to //terraform/aws/athena"* ]]; then
    echo "ok    $c: validate stops with the move message"
  else
    echo "FAIL  $c: validate exit $vcode: $vout"; fails=$((fails + 1))
  fi
  out="$(terraform -chdir="$d" plan -input=false -no-color 2>&1)"; code=$?
  if [[ $code -ne 0 && "$out" == *"moved to //terraform/aws/athena"* \
        && "$out" != *"Unsupported argument"* && "$out" != *"Unsupported attribute"* \
        && "$out" != *"will be destroyed"* && "$out" != *"will be created"* ]]; then
    echo "ok    $c: plan stops with the move message"
  else
    echo "FAIL  $c: exit $code: $out"; fails=$((fails + 1))
  fi
done

# The moved module and its example are still valid configurations (their .terraform/ is gitignored).
for d in terraform/aws/athena examples/aws/athena; do
  if out="$(terraform -chdir="$REPO/$d" init -backend=false -input=false -no-color 2>&1 \
            && terraform -chdir="$REPO/$d" validate -no-color 2>&1)"; then
    echo "ok    $d: validates"
  else
    echo "FAIL  $d: $out"; fails=$((fails + 1))
  fi
done

echo
[[ $fails -eq 0 ]] && echo "PASS" || { echo "FAIL ($fails)"; exit 1; }
