#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname -- "$0")"
# The manager substitutes a shell-quoted command when copying this template.
docker_command=(@DOCKER_COMMAND@)

# Run only after stopping the old and new stacks; this replaces archived volumes.
for archive in ./*.tar; do
    [ -f "${archive}" ] || continue
    volume_name=${archive#./}
    volume_name=${volume_name%.tar}
    if "${docker_command[@]}" volume inspect "${volume_name}" >/dev/null 2>&1; then
        "${docker_command[@]}" volume rm "${volume_name}"
    fi
    "${docker_command[@]}" volume create --name="${volume_name}"
    "${docker_command[@]}" run --rm -v "${volume_name}:/data" -v "$(pwd):/backup:ro" \
        ubuntu tar --same-owner -xzpf "/backup/${volume_name}.tar" -C /data
done
