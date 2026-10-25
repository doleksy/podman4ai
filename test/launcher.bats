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
  [[ "$output" == *"p4a podman"* ]]
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
