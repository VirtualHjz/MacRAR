#!/bin/bash
set -e
cd "$(dirname "$0")/.."
rm -rf .build
swift build --product EngineTest
