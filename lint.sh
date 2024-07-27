#!/usr/bin/env bash

set -ex

prettier -c www
zig fmt --check src
zig build
./zig-out/bin/make_site --input-www www --output output --index-wasm ./zig-out/bin/index.wasm --osm-data ./res/planet_-123.114,49.284_-123.107,49.287.osm

valgrind --suppressions=suppressions.valgrind --leak-check=full --track-fds=yes --error-exitcode=1 ./zig-out/bin/sphmap_nogui output/map_data.bin output/map_data.json
