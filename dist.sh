#!/bin/sh
# Builds rad for its targets (see targets/), each into dist/<target>
#
#   ./dist.sh                   all targets
#   ./dist.sh <target>          one target
#   ./dist.sh --deploy <target> build and upload it to DEPLOY_<TARGET> of .env, e.g. DEPLOY_PANZERSCHOKOLADE=user@host:/var/www/rad/
set -e
cd "$(dirname "$0")"

deploy=
targets=
for arg in "$@"; do
  case $arg in
  --deploy) deploy=1 ;;
  *) targets="$targets $arg" ;;
  esac
done
[ -n "$targets" ] || {
  [ -z "$deploy" ] || {
    echo "Which target to deploy?" >&2
    exit 1
  }
  targets=$(ls targets)
}

for target in $targets; do
  dir=targets/$target
  [ -f "$dir/config.json" ] || {
    echo "Unknown target: $target" >&2
    exit 1
  }
  out=dist/$target
  echo "--- $target"
  rm -rf "$out"
  mkdir -p "$out"
  haxe build.hxml -D rad-target="$target"
  npx --no-install esbuild build/rad.js --bundle --format=esm --minify --log-level=warning --outfile="$out/rad.js"
  npx --no-install sass --pkg-importer=node --no-source-map --style=compressed "$dir/theme.scss" "$out/rad.css"
  # the static files, not the development build
  tar -C web --exclude='rad.js' --exclude='rad.css' --exclude='_*' -cf - . | tar -C "$out" -xf -
  if [ -n "$deploy" ]; then
    . ./.env
    var=DEPLOY_$(echo "$target" | tr 'a-z-' 'A-Z_')
    eval dest=\${$var:-}
    [ -n "$dest" ] || {
      echo "Set $var in .env" >&2
      exit 1
    }
    rsync -avz "$out/" "$dest"
  fi
done
