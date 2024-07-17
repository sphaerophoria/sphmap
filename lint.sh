#!/usr/bin/env bash

set -ex

prettier -c www
zig fmt --check src
#zig build
