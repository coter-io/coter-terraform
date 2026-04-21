#!/usr/bin/env bash
# Replaced by deployer: align with MakeService.ssh (CI/Docker; avoids accept-new / agent key mismatch).
SSH_OPTS=( -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5 )
if [[ -n "${SSH_IDENTITY_FILE:-}" ]]; then
  SSH_OPTS+=( -o IdentitiesOnly=yes -i "$SSH_IDENTITY_FILE" )
fi

