default:
    @just --list

install:
    deno install --frozen --allow-scripts=npm:esbuild,npm:sharp

dev:
    deno task dev

check:
    deno task check

build:
    deno task build

preview:
    deno task preview

# Validate and push committed source; GitHub Actions publishes the site.
deploy:
    #!/usr/bin/env bash
    set -euo pipefail
    [[ "$(git branch --show-current)" == main ]] || { echo 'Deploy from main.' >&2; exit 1; }
    [[ -z "$(git status --porcelain)" ]] || { echo 'Commit your changes before deploying.' >&2; exit 1; }
    [[ "$(git remote get-url --push origin)" == 'git@github.com:ATOMLubover/ATOMLubover.github.io.git' ]] || { echo 'Unexpected origin URL.' >&2; exit 1; }
    deno task check
    deno task build
    git push origin main
    echo 'Deployment status: https://github.com/ATOMLubover/ATOMLubover.github.io/actions/workflows/build.yml'
