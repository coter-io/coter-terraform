# Shared SSH/SCP options for deploy/*.sh and scripts/*.sh (source this file).
# Optional: SSH_IDENTITY_FILE when ~/.ssh is not populated (Docker/CI).
# The key file should be mode 600 or OpenSSH will refuse it.
SSH_OPTS=( -o StrictHostKeyChecking=accept-new )
if [[ -n "${SSH_IDENTITY_FILE:-}" ]]; then
    SSH_OPTS+=( -i "$SSH_IDENTITY_FILE" )
fi
