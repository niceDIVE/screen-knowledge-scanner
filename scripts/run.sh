#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
dotnet run --project src/Screen.App -- --Scanner:DataDirectory="$project_root/data" "$@"
