#!/usr/bin/env bash

# ref: https://stackoverflow.com/questions/11258737/restore-git-submodules-from-gitmodules

_D=$(readlink -f "$(dirname "$0")")

set -xe

# by default, it is under a worktree of averageX project
TARGET_BRANCH_GIT_DIR="$_D/../dev"

rsync --archive "${TARGET_BRANCH_GIT_DIR}"/{.envrc,flake.lock,flake.nix} "$_D"/
rsync --archive "${TARGET_BRANCH_GIT_DIR}"/packages/contracts/ "$_D"/packages/contracts/
# TODO using xxd -r -p due to some stupid forge ffi hex string issue
(cd "${TARGET_BRANCH_GIT_DIR}"; ./tasks/show-git-rev.sh) > sync.git-rev
