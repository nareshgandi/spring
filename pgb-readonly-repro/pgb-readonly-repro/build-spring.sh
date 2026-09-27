#!/usr/bin/env bash
# Builds spring-app/target/readonly-repro.jar.
# Uses system mvn if present, otherwise downloads Maven 3.9.9 into ./tools (no root needed).
# PGJDBC_VERSION=42.x.y ./build-spring.sh   -> build with the customer's exact pgJDBC version
set -euo pipefail
cd "$(dirname "$0")"

MVN=mvn
if ! command -v mvn >/dev/null 2>&1; then
  V=3.9.9
  if [ ! -x "tools/apache-maven-$V/bin/mvn" ]; then
    echo "==> Downloading Maven $V into ./tools"
    mkdir -p tools
    curl -fsSL "https://archive.apache.org/dist/maven/maven-3/$V/binaries/apache-maven-$V-bin.tar.gz" | tar xz -C tools
  fi
  MVN="$PWD/tools/apache-maven-$V/bin/mvn"
fi

ARGS=(-q -f spring-app/pom.xml -DskipTests package)
if [ -n "${PGJDBC_VERSION:-}" ]; then
  echo "==> Building with pgJDBC $PGJDBC_VERSION"
  ARGS+=("-Dpostgresql.version=$PGJDBC_VERSION")
fi
"$MVN" "${ARGS[@]}"
echo "==> Built spring-app/target/readonly-repro.jar"
