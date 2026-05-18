#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VIEWER_DIR="${PARQUET_VIEWER_DIR:-"${ROOT_DIR}/parquet-viewer"}"
RUNTIME_DIR="${PARQUET_VIEWER_RUNTIME_DIR:-"${ROOT_DIR}/site/public/parquet-viewer-runtime"}"
DX_BIN="${DX:-dx}"
DX_VERSION="${PARQUET_VIEWER_DX_VERSION:-0.7.3}"

if ! command -v "${DX_BIN}" >/dev/null 2>&1; then
  cat >&2 <<'MSG'
Dioxus CLI is required to build the vendored Parquet viewer runtime.
Install it with:

  cargo install dioxus-cli --version 0.7.3 --locked

MSG
  exit 127
fi

INSTALLED_DX_VERSION="$("${DX_BIN}" --version | sed -n 's/.* \([0-9][0-9.]*\).*/\1/p' | head -n 1)"
if [[ "${INSTALLED_DX_VERSION}" != "${DX_VERSION}" ]]; then
  echo "Dioxus CLI ${DX_VERSION} is required; found ${INSTALLED_DX_VERSION:-unknown} at ${DX_BIN}." >&2
  exit 1
fi

if [[ ! -f "${VIEWER_DIR}/Cargo.toml" ]]; then
  echo "Parquet viewer source package not found: ${VIEWER_DIR}" >&2
  exit 1
fi

rm -rf "${VIEWER_DIR}/target/dx"
(cd "${VIEWER_DIR}" && "${DX_BIN}" build --platform web --release)

PUBLIC_DIR="$(find "${VIEWER_DIR}/target/dx" -path "*/release/web/public" -type d | sort | tail -n 1)"
if [[ -z "${PUBLIC_DIR}" || ! -d "${PUBLIC_DIR}" ]]; then
  echo "Dioxus build output was not found under ${VIEWER_DIR}/target/dx." >&2
  exit 1
fi

rm -rf "${RUNTIME_DIR}"
mkdir -p "${RUNTIME_DIR}"
cp -R "${PUBLIC_DIR}/." "${RUNTIME_DIR}/"

find_asset() {
  local pattern="$1"
  local asset
  asset="$(find "${RUNTIME_DIR}/assets" -maxdepth 1 -type f -name "${pattern}" | sort | tail -n 1)"
  if [[ -z "${asset}" ]]; then
    echo "Could not find runtime asset matching ${pattern}." >&2
    exit 1
  fi
  basename "${asset}"
}

SCRIPT_ASSET="$(find_asset "parquet-viewer-*.js")"
WASM_ASSET="$(find_asset "parquet-viewer_bg-*.wasm")"
TAILWIND_ASSET="$(find_asset "tailwind-*.css")"
MAIN_CSS_ASSET="$(find_asset "main-*.css")"
TOAST_CSS_ASSET="$(find_asset "toast-*.css")"
ICON_ASSET="$(find_asset "icon-192x192-*.png")"
VERSION="$(sed -n 's/^version = "\(.*\)"/\1/p' "${VIEWER_DIR}/Cargo.toml" | head -n 1)"

patch_runtime_asset_paths() {
  local script_file="${RUNTIME_DIR}/assets/${SCRIPT_ASSET}"
  local wasm_source='module_or_path:"/./assets/'"${WASM_ASSET}"'"'
  local wasm_target='module_or_path:new URL("./'"${WASM_ASSET}"'",import.meta.url)'

  if [[ ! -f "${script_file}" ]]; then
    echo "Could not find runtime script: ${script_file}" >&2
    exit 1
  fi

  if ! grep -Fq "${wasm_source}" "${script_file}"; then
    echo "Could not find Dioxus WASM bootstrap path in ${script_file}." >&2
    exit 1
  fi

  perl -0pi -e 's|\Q'"${wasm_source}"'\E|'"${wasm_target}"'|g' "${script_file}"

  if grep -Fq 'module_or_path:"/./assets/' "${script_file}"; then
    echo "Dioxus runtime still contains a root-relative WASM path after patching." >&2
    exit 1
  fi

  if [[ -f "${RUNTIME_DIR}/index.html" ]]; then
    perl -0pi -e 's|"/\./assets/|"./assets/|g' "${RUNTIME_DIR}/index.html"
  fi
}

patch_runtime_asset_paths

cat > "${RUNTIME_DIR}/manifest.json" <<EOF
{
  "source": "parquet-viewer",
  "version": "${VERSION}",
  "script": "./assets/${SCRIPT_ASSET}",
  "wasm": "./assets/${WASM_ASSET}",
  "styles": [
    "./assets/${TAILWIND_ASSET}",
    "./assets/${MAIN_CSS_ASSET}",
    "./assets/${TOAST_CSS_ASSET}"
  ],
  "icon": "./assets/${ICON_ASSET}"
}
EOF

cat > "${RUNTIME_DIR}/NOTICE.md" <<EOF
# Parquet Viewer Runtime

The Parquet viewer runtime is built from source vendored from XiangpengHao/parquet-viewer ${VERSION} into this repository's \`parquet-viewer/\` package.

Use \`npm --prefix site run build:parquet-viewer\` to rebuild these runtime assets after changing the vendored viewer source.

Upstream source: https://github.com/XiangpengHao/parquet-viewer

Upstream licenses: Apache-2.0 or MIT.
EOF

echo "Built Parquet viewer runtime at ${RUNTIME_DIR}"
