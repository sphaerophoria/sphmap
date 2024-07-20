#!/usr/bin/env bash

set -ex

prettier -c www
zig fmt --check src
zig build -Dosm_data=./res/planet_-123.114,49.284_-123.107,49.287.osm
