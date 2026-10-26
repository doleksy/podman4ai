#!/usr/bin/env bats
# The Launcher itself: help, dispatch and usage errors.

load helpers

@test "an unknown subcommand fails, names it and points at --help" {
  run p4a frobnicate
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown command 'frobnicate'"* ]]
  [[ "$output" == *"p4a --help"* ]]
  [ -z "$(podman_calls)" ]
}

@test "--help lists the commands" {
  run p4a --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: p4a"* ]]
  [[ "$output" == *"p4a machine"* ]]
  [[ "$output" == *"p4a image build"* ]]
  [[ "$output" == *"p4a podman"* ]]
  for command in new start stop shell; do
    [[ "$output" == *"p4a $command "* ]]
  done
  [ -z "$(podman_calls)" ]
}

@test "project commands with the wrong arguments fail with a usage error" {
  for args in "new" "new not-a-repo" "new a/b c/d" "start" "stop a b" "shell" "shell hello-world git log"; do
    # shellcheck disable=SC2086
    run p4a $args
    [ "$status" -eq 2 ]
    [[ "$output" == *"p4a --help"* ]]
  done
  [ -z "$(podman_calls)" ]
}

@test "machine --help lists the machine commands" {
  run p4a machine --help
  [ "$status" -eq 0 ]
  for command in create start stop status; do
    [[ "$output" == *"$command"* ]]
  done
  [ -z "$(podman_calls)" ]
}

@test "an unknown machine subcommand fails, names it and points at machine --help" {
  run p4a machine explode
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown command 'machine explode'"* ]]
  [[ "$output" == *"p4a machine --help"* ]]
  [ -z "$(podman_calls)" ]
}

@test "image --help lists the image commands" {
  run p4a image --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"build"* ]]
  [ -z "$(podman_calls)" ]
}

@test "an unknown image subcommand fails, names it and points at image --help" {
  run p4a image explode
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown command 'image explode'"* ]]
  [[ "$output" == *"p4a image --help"* ]]
  [ -z "$(podman_calls)" ]
}
