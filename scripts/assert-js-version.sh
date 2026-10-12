#!/usr/bin/env sh
set -eu

expected_node=$(cat .node-version)
expected_pnpm=$(node --input-type=module -e 'import p from "./package.json" with { type: "json" }; console.log(p.packageManager.split("@")[1])')
[ "$(node --version)" = "v$expected_node" ] || {
    echo "Node.js $expected_node is required." >&2
    exit 1
}
[ "$(pnpm --version)" = "$expected_pnpm" ] || {
    echo "pnpm $expected_pnpm is required." >&2
    exit 1
}
node --input-type=module -e '
import { existsSync, realpathSync } from "node:fs";
import { dirname, resolve } from "node:path";
const bin = dirname(realpathSync(process.execPath));
for (const path of ["npm", "npx", "../lib/node_modules/npm", "node_modules/npm"]) {
  if (existsSync(resolve(bin, path))) throw new Error("The selected Node.js must not bundle npm");
}
'
