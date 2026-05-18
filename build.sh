#!/usr/bin/env bash
#
# Build relocatable libkrun + libkrunfw artefacts for the host platform.
#
# Output: ./dist/libkrun-${LIBKRUN_VERSION}-${TARGET}.tar.gz
#
# The tarball layout:
#   lib/libkrun.${ext}              with @rpath / $ORIGIN install name
#   lib/libkrunfw.${ext}            with @rpath / $ORIGIN install name
#   include/libkrun.h
#   lib/pkgconfig/libkrun.pc        synthesised, prefix placeholder
#                                   rewritten by the consumer
#
# Versioning:
#   libkrun and libkrunfw use *independent* version schemes. The
#   pairing is authoritative via slp/krun's Homebrew formulas. We pin
#   both in this repo:
#     version.txt             libkrun release tag (e.g. 1.18.0)
#     libkrunfw-version.txt   libkrunfw release tag (e.g. 5.3.0)
#
# Build approach:
#   - libkrunfw: download upstream's prebuilt arch tarball + run its
#     bundled `make` + `make install`. Much faster than building the
#     custom Linux kernel from source.
#   - libkrun: clone the source tag and `make`, with PKG_CONFIG_PATH
#     pointing at the staged libkrunfw.
#
# Usage:
#   ./build.sh                    Build for the host's native triple.
#   TARGET=foo ./build.sh         Override the auto-detected target triple.
#
# Required tools:
#   - bash, make, gcc/clang
#   - cargo (Rust 1.75+)
#   - patchelf (Linux) or install_name_tool (macOS, ships with Xcode CLT)
#   - curl, tar, gzip, sha256sum / shasum
#   - pkg-config
#
# Exit codes:
#   0   Success, ./dist/libkrun-${LIBKRUN_VERSION}-${TARGET}.tar.gz exists.
#   1   Unknown / unsupported target triple.
#   2   Dependency missing.
#   3   Upstream download or build failed.
#   4   Relocation failed.

set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve versions + TARGET
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIBKRUN_VERSION="$(tr -d '[:space:]' < "${SCRIPT_DIR}/version.txt")"
LIBKRUNFW_VERSION="$(tr -d '[:space:]' < "${SCRIPT_DIR}/libkrunfw-version.txt")"

if [[ -z "${TARGET:-}" ]]; then
  TARGET="$(rustc -vV | awk '/^host:/ {print $2}')"
fi

# Map host target → libkrunfw upstream arch + dylib extension.
# The libkrunfw kernel always runs inside a Linux microVM regardless
# of the host OS, so macOS arm64 uses the same kernel image as Linux
# arm64. Only the dylib loader format differs (Mach-O vs ELF), which
# the libkrunfw build handles via its host-aware Makefile.
case "${TARGET}" in
  aarch64-apple-darwin)
    DYLIB_EXT="dylib"
    LIBKRUNFW_ASSET="libkrunfw-prebuilt-aarch64.tgz"
    BACKEND="hvf"
    ;;
  x86_64-unknown-linux-gnu)
    DYLIB_EXT="so"
    LIBKRUNFW_ASSET="libkrunfw-x86_64.tgz"
    BACKEND="kvm"
    ;;
  aarch64-unknown-linux-gnu)
    DYLIB_EXT="so"
    LIBKRUNFW_ASSET="libkrunfw-aarch64.tgz"
    BACKEND="kvm"
    ;;
  *)
    echo "error: unsupported target triple '${TARGET}'" >&2
    echo "supported: aarch64-apple-darwin, x86_64-unknown-linux-gnu, aarch64-unknown-linux-gnu" >&2
    exit 1
    ;;
esac

echo "==> Building libkrun ${LIBKRUN_VERSION} (+ libkrunfw ${LIBKRUNFW_VERSION}) for ${TARGET}"
echo "==> Backend: ${BACKEND}, libkrunfw asset: ${LIBKRUNFW_ASSET}"

# ---------------------------------------------------------------------------
# Sanity-check tooling
# ---------------------------------------------------------------------------

need() {
  command -v "$1" > /dev/null 2>&1 || { echo "error: missing required tool '$1'" >&2; exit 2; }
}

need bash
need make
need cargo
need curl
need tar
need gzip
need pkg-config
command -v sha256sum > /dev/null 2>&1 || command -v shasum > /dev/null 2>&1 || { echo "error: missing sha256sum or shasum" >&2; exit 2; }

if [[ "${TARGET}" == *darwin* ]]; then
  need install_name_tool
else
  need patchelf
fi

# ---------------------------------------------------------------------------
# Scratch directories
# ---------------------------------------------------------------------------

WORK="${SCRIPT_DIR}/build/${TARGET}"
DIST="${SCRIPT_DIR}/dist"
STAGE="${WORK}/stage"
PREFIX="${WORK}/prefix"

rm -rf "${WORK}"
mkdir -p "${WORK}" "${STAGE}/lib/pkgconfig" "${STAGE}/include" "${PREFIX}" "${DIST}"

# ---------------------------------------------------------------------------
# 1) libkrunfw: download prebuilt tarball, run its bundled make + install.
# ---------------------------------------------------------------------------

LIBKRUNFW_URL="https://github.com/containers/libkrunfw/releases/download/v${LIBKRUNFW_VERSION}/${LIBKRUNFW_ASSET}"
echo "==> Downloading libkrunfw v${LIBKRUNFW_VERSION} (${LIBKRUNFW_ASSET})"
curl --fail --silent --show-error --location \
  --output "${WORK}/${LIBKRUNFW_ASSET}" \
  "${LIBKRUNFW_URL}" \
  || { echo "error: failed to download libkrunfw from ${LIBKRUNFW_URL}" >&2; exit 3; }

mkdir -p "${WORK}/libkrunfw"
tar -xzf "${WORK}/${LIBKRUNFW_ASSET}" -C "${WORK}/libkrunfw" --strip-components=1 \
  || { echo "error: failed to extract libkrunfw tarball" >&2; exit 3; }

# Upstream publishes two tarball shapes under different asset names:
#   - macOS `libkrunfw-prebuilt-<arch>.tgz`: source-ish tarball with a
#     Makefile that compiles kernel.c into a dylib. We run make.
#   - Linux `libkrunfw-<arch>.tgz`: fully prebuilt .so files. We just
#     install them.
# Detect by Makefile presence rather than asset name so this is robust
# to upstream renaming.
if [[ -f "${WORK}/libkrunfw/Makefile" ]]; then
  (
    cd "${WORK}/libkrunfw"
    echo "==> Building libkrunfw via its bundled Makefile"
    make -j"$(getconf _NPROCESSORS_ONLN || echo 4)" \
      || { echo "error: libkrunfw make failed" >&2; exit 3; }
    echo "==> Installing libkrunfw into ${PREFIX}"
    make PREFIX="${PREFIX}" install \
      || { echo "error: libkrunfw make install failed" >&2; exit 3; }
  )
else
  echo "==> Installing prebuilt libkrunfw binaries into ${PREFIX}"
  mkdir -p "${PREFIX}/lib64"
  shopt -s nullglob
  files=( "${WORK}/libkrunfw"/libkrunfw.* )
  shopt -u nullglob
  if (( ${#files[@]} == 0 )); then
    echo "error: tarball has no Makefile and no libkrunfw.* binaries" >&2
    ls -la "${WORK}/libkrunfw/" >&2
    exit 3
  fi
  cp -P "${files[@]}" "${PREFIX}/lib64/"
fi

# ---------------------------------------------------------------------------
# 2) libkrun: clone the source tag and build, pointing pkg-config at
#    the staged libkrunfw so the linker finds it.
# ---------------------------------------------------------------------------

echo "==> Cloning libkrun v${LIBKRUN_VERSION}"
curl --fail --silent --show-error --location \
  --output "${WORK}/libkrun.tar.gz" \
  "https://github.com/containers/libkrun/archive/refs/tags/v${LIBKRUN_VERSION}.tar.gz" \
  || { echo "error: failed to download libkrun source tarball" >&2; exit 3; }
mkdir -p "${WORK}/libkrun"
tar -xzf "${WORK}/libkrun.tar.gz" -C "${WORK}/libkrun" --strip-components=1 \
  || { echo "error: failed to extract libkrun source" >&2; exit 3; }

(
  cd "${WORK}/libkrun"
  echo "==> Building libkrun"
  export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig:${PREFIX}/lib64/pkgconfig:${PKG_CONFIG_PATH:-}"
  export LIBRARY_PATH="${PREFIX}/lib:${PREFIX}/lib64:${LIBRARY_PATH:-}"
  export LD_LIBRARY_PATH="${PREFIX}/lib:${PREFIX}/lib64:${LD_LIBRARY_PATH:-}"
  # Tell libkrun's Makefile to install under our PREFIX.
  make -j"$(getconf _NPROCESSORS_ONLN || echo 4)" \
    || { echo "error: libkrun make failed" >&2; exit 3; }
  make PREFIX="${PREFIX}" install \
    || { echo "error: libkrun make install failed" >&2; exit 3; }
)

# ---------------------------------------------------------------------------
# 3) Stage the artefacts we want in the final tarball.
# ---------------------------------------------------------------------------

# libkrunfw + libkrun .dylib/.so files. Both might be installed under
# lib/ or lib64/ depending on the upstream Makefile; copy whatever
# exists. The glob `lib*.dylib*` / `lib*.so*` covers both conventions:
#   Linux:  libkrunfw.so, libkrunfw.so.5, libkrunfw.so.5.3.0
#           (version SUFFIX after the extension)
#   macOS:  libkrun.dylib, libkrun.1.dylib, libkrun.1.18.0.dylib
#           (version INFIX between name and extension)
# A naive `libkrun.${DYLIB_EXT}*` glob only matches the Linux pattern
# and leaves the macOS versioned files behind, producing dangling
# symlinks. Anchoring with `lib*` keeps `libkrun.pc` and `libkrun.h`
# out of the result.
echo "==> Staging dylibs"
for libdir in "${PREFIX}/lib" "${PREFIX}/lib64"; do
  [[ -d "$libdir" ]] || continue
  find "$libdir" -maxdepth 1 \( -name "libkrun*.${DYLIB_EXT}*" -o -name "libkrunfw*.${DYLIB_EXT}*" \) \
    -exec cp -P {} "${STAGE}/lib/" \;
done

# Headers (only libkrun.h is what consumers need, libkrunfw is loaded
# at runtime, not directly compiled against).
cp "${PREFIX}/include/libkrun.h" "${STAGE}/include/" \
  || { echo "error: libkrun.h not found in ${PREFIX}/include" >&2; exit 3; }

# Verify we got the unversioned dylib symlinks (consumers link via -lkrun
# which resolves to libkrun.dylib / libkrun.so).
for lib in libkrun libkrunfw; do
  if ! ls "${STAGE}/lib/${lib}.${DYLIB_EXT}" > /dev/null 2>&1; then
    echo "error: missing ${STAGE}/lib/${lib}.${DYLIB_EXT} after staging" >&2
    ls -la "${STAGE}/lib/" >&2
    exit 3
  fi
done

# ---------------------------------------------------------------------------
# 4) Relocate install names so the dylibs are portable.
# ---------------------------------------------------------------------------

echo "==> Rewriting install names for relocatability"
echo "==> Stage layout before relocation:"
ls -la "${STAGE}/lib/" || true
if [[ "${TARGET}" == *darwin* ]]; then
  for lib in libkrun libkrunfw; do
    # Fully resolve the symlink chain to the actual versioned dylib.
    # Upstream libkrun lays out e.g.
    #   libkrun.dylib -> libkrun.1.dylib -> libkrun.1.18.0.dylib
    # `readlink` only follows one level; `realpath` chases the whole
    # chain. macOS's built-in realpath (BSD) is available on macOS 12+.
    sym="${STAGE}/lib/${lib}.${DYLIB_EXT}"
    if [[ ! -e "$sym" ]]; then
      echo "error: ${sym} not found after staging" >&2
      ls -la "${STAGE}/lib/" >&2
      exit 4
    fi
    target_file="$(realpath "$sym")"
    if [[ ! -f "$target_file" ]]; then
      echo "error: realpath of ${sym} -> ${target_file} is not a regular file" >&2
      ls -la "${STAGE}/lib/" >&2
      exit 4
    fi
    install_name_tool -id "@rpath/${lib}.${DYLIB_EXT}" "$target_file" || exit 4
  done
  # libkrun loads libkrunfw at runtime, rewrite its LC_LOAD_DYLIB
  # entry to @rpath too. The original path varies; cover common ones.
  for libkrun_file in "${STAGE}/lib/libkrun.${DYLIB_EXT}" "${STAGE}/lib/libkrun.${DYLIB_EXT}."*; do
    [[ -f "$libkrun_file" && ! -L "$libkrun_file" ]] || continue
    otool -L "$libkrun_file" | awk 'NR>1 && /libkrunfw/ {print $1}' | while read -r ref; do
      install_name_tool -change "$ref" "@rpath/libkrunfw.${DYLIB_EXT}" "$libkrun_file" || true
    done
  done
else
  # Linux: set RUNPATH = $ORIGIN so the loader looks next to the .so.
  for lib in libkrun libkrunfw; do
    # Resolve the full symlink chain to the real ELF. Upstream lays out
    # e.g. libkrun.so -> libkrun.so.1 -> libkrun.so.1.18.0 (two levels),
    # so a single-level `readlink` stops at an intermediate symlink and
    # patchelf would rewrite that instead of the actual binary. `realpath`
    # chases the whole chain (mirrors the install_name_tool step above).
    sym="${STAGE}/lib/${lib}.${DYLIB_EXT}"
    if [[ ! -e "$sym" ]]; then
      echo "error: ${sym} not found after staging" >&2
      ls -la "${STAGE}/lib/" >&2
      exit 4
    fi
    target_file="$(realpath "$sym")"
    if [[ ! -f "$target_file" ]]; then
      echo "error: realpath of ${sym} -> ${target_file} is not a regular file" >&2
      ls -la "${STAGE}/lib/" >&2
      exit 4
    fi
    patchelf --set-rpath '$ORIGIN' "$target_file" || exit 4
  done
fi

# ---------------------------------------------------------------------------
# 5) Synthesise libkrun.pc, placeholder prefix rewritten by consumer.
# ---------------------------------------------------------------------------

cat > "${STAGE}/lib/pkgconfig/libkrun.pc" <<EOF
prefix=__VENDOR_PREFIX__
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: libkrun
Description: Dynamic library for spawning microVMs
Version: ${LIBKRUN_VERSION}
Libs: -L\${libdir} -lkrun
Cflags: -I\${includedir}
EOF

# ---------------------------------------------------------------------------
# 6) Tar + checksum the result.
# ---------------------------------------------------------------------------

TARBALL="libkrun-${LIBKRUN_VERSION}-${TARGET}.tar.gz"
echo "==> Producing ${TARBALL}"
tar -C "${STAGE}" -czf "${DIST}/${TARBALL}" .

if command -v sha256sum > /dev/null 2>&1; then
  (cd "${DIST}" && sha256sum "${TARBALL}")
else
  (cd "${DIST}" && shasum -a 256 "${TARBALL}")
fi

echo "==> Done. Tarball at ${DIST}/${TARBALL}"
