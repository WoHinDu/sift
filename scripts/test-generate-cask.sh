#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/sift-cask-test.XXXXXX")"
trap 'rm -f "${fixture}/signed.rb" "${fixture}/unsigned.rb"; rmdir "${fixture}"' EXIT
sha=142d1ce522b6f3f7adbe7070ad9dfb0b404bff34871216a1837cb1322cdc9cdb
for mode in signed unsigned; do
  bash "${root}/scripts/generate-cask.sh" 0.1.15 "${sha}" dominik-bura/sift "${mode}" > "${fixture}/${mode}.rb"
  ruby -c "${fixture}/${mode}.rb"
done
grep -Fq 'app "Sift.app"' "${fixture}/signed.rb"
grep -Fq 'auto_updates true' "${fixture}/signed.rb"
grep -Fq "${sha}" "${fixture}/signed.rb"
grep -Fq 'Sift-#{version}.dmg' "${fixture}/signed.rb"
grep -Fq "isn't notarized" "${fixture}/unsigned.rb"
! grep -q 'caveats' "${fixture}/signed.rb"
! grep -Eq 'xattr|sudo|system_command|--no-quarantine' "${fixture}/unsigned.rb"
for args in 'bad-version' '1.2.3 bad-sha owner/repo' "1.2.3 ${sha} bad-repo" "1.2.3 ${sha} owner/repo bad-mode"; do
  if bash "${root}/scripts/generate-cask.sh" ${args} >/dev/null 2>&1; then
    echo "Accepted invalid cask arguments" >&2; exit 1
  fi
done
echo 'Cask generator tests passed'
