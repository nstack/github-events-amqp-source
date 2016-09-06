#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

# build/install in local env
stack build
rm -rf ./bin
mkdir -p ./bin
stack install --local-bin-path ./bin

# copy into a docker image for deployment
docker build -t nstack/github-events-amqp-source:latest .

# push docker image for running on ECS
docker push nstack/github-events-amqp-source:latest
