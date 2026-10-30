#!/usr/bin/env bash
# Package VeriIDE into desktop bundles.
#
# Why this script exists (each item was observed on the Manjaro dev host):
#   * `pnpm tauri build` run from web/ aborts with
#     "Couldn't recognize the current folder as a Tauri project": the CLI only
#     searches downward for tauri.conf.json, which lives in ../src-tauri.
#   * The config's frontend hooks run in the component root, not in src-tauri
#     (verified: `beforeBuildCommand` sees /…/veri-ide), so they say
#     `pnpm --dir web ...`. A bare `pnpm dev` there fails -- no package.json.
#   * bundle.targets is "all", but deb needs dpkg-deb and rpm needs rpmbuild.
#     Whichever tool is missing is reported instead of silently skipping it.
#
# The bundle carries its own Python environment and the two runtime tools the
# sidecar shells out to (veristc, sim), so the packaged app does not depend on
# this checkout: see src-tauri/payload/ and VERIDE_BIN_DIR in main.rs.
#
# Payload layout is a contract with tauri.conf.json's `bundle.resources`, and it
# must be a *directory* key ("payload/python"), not a glob ("payload/python/**"):
# a glob's matches are flattened into the target directory, which would scatter
# the virtualenv and leave no importable package.
set -euo pipefail

IDE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$IDE_DIR/.." && pwd)"
TAURI_DIR="$IDE_DIR/src-tauri"
PAYLOAD="$TAURI_DIR/payload"
VENV="$IDE_DIR/.venv"

# The bundler runs the config's frontend hooks, so `pnpm` has to be on PATH.
if ! command -v pnpm >/dev/null 2>&1 && [ -x /home/wei/.local/share/pnpm/bin/pnpm ]; then
  PATH="/home/wei/.local/share/pnpm/bin:$PATH"
  export PATH
fi

# Formats to build: anything the host can actually bundle.
FORMATS=()
command -v dpkg-deb  >/dev/null 2>&1 && FORMATS+=(deb)
command -v rpmbuild  >/dev/null 2>&1 && FORMATS+=(rpm)
FORMATS+=(appimage)
echo "==> bundle formats: ${FORMATS[*]}"
command -v dpkg-deb >/dev/null 2>&1 || echo "    dpkg-deb missing: no .deb on this host"
command -v rpmbuild >/dev/null 2>&1 || echo "    rpmbuild missing: no .rpm on this host"

for tool in "$REPO_ROOT/build/bin/veristc" "$REPO_ROOT/build/bin/sim"; do
  [ -x "$tool" ] || { echo "!! $tool missing -- run 'make all' in $REPO_ROOT first"; exit 1; }
done
[ -x "$VENV/bin/python" ] || { echo "!! $VENV missing -- create it and 'pip install -e .'"; exit 1; }
[ -d "$IDE_DIR/web/node_modules" ] || { echo "!! web/node_modules missing -- 'pnpm install' in web/"; exit 1; }

echo "==> payload: relocatable python environment"
PYDIR="$("$VENV/bin/python" -c 'import sys; print(f"python{sys.version_info[0]}.{sys.version_info[1]}")')"
SITE="$PAYLOAD/python/lib/$PYDIR/site-packages"
rm -rf "$PAYLOAD"
mkdir -p "$PAYLOAD/bin" "$PAYLOAD/python"
# -L dereferences the venv's interpreter symlink, so the copy is self-contained.
cp -aL "$VENV"/. "$PAYLOAD/python/"
# The dev install is editable and points back into this checkout; a bundle must
# not. Drop the pointer and lay the package itself into site-packages instead.
find "$SITE" -maxdepth 1 \( -name '__editable__*' -o -name '*.egg-info' \) -exec rm -rf {} +
cp -a "$IDE_DIR/src/veri_ide" "$SITE/"
# `cp -L` dereferenced the venv's lib64 -> lib symlink into a second copy of
# site-packages; the interpreter only reads lib.
rm -rf "$PAYLOAD/python/lib64"
echo "    veri_ide -> $SITE/veri_ide"

# Prove the payload is relocatable before spending minutes bundling: it must
# import itself, not this checkout.
"$PAYLOAD/python/bin/python3" -c "
import sys, veri_ide
assert veri_ide.__file__.startswith(sys.prefix), veri_ide.__file__
import uvicorn
print('    payload python ok:', sys.version.split()[0], veri_ide.__file__)
"

echo "==> payload: runtime tools"
cp -a "$REPO_ROOT/build/bin/veristc" "$REPO_ROOT/build/bin/sim" "$PAYLOAD/bin/"
du -sh "$PAYLOAD" | sed 's/^/    /'

echo "==> bundling"
BUNDLES="$(IFS=,; echo "${FORMATS[*]}")"
MARKER="$(mktemp)"
(cd "$TAURI_DIR" && "../web/node_modules/.bin/tauri" build --bundles "$BUNDLES" | tail -12)

echo "==> artifacts"
# Only what this run produced: a previous run's .deb/.rpm still sits in the tree,
# and listing it here reads as if it had just been built.
find "$TAURI_DIR/target/release/bundle" -maxdepth 2 -type f \
  \( -name '*.AppImage' -o -name '*.deb' -o -name '*.rpm' \) \
  -newer "$MARKER" -exec ls -lh {} \; | awk '{print "   ", $NF, $5}'
rm -f "$MARKER"
