#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

stack build
rm -rf ./bin
mkdir -p ./bin
stack install --local-bin-path ./bin
docker build -t nstack/github-events-amqp-source .

