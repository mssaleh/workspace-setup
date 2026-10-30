#!/usr/bin/env bash
set -euo pipefail

# Container 1.6.1 restarts its builder when requested resources change.
# https://github.com/apple/container/blob/1.6.1/Sources/ContainerBuild/Builder%2BStart.swift
[[ $# == 2 ]] || { printf 'usage: %s CPUS MEMORY\n' "$0" >&2; exit 2; }
container system start --enable-kernel-install
container builder start --cpus "$1" --memory "$2"
container builder status
