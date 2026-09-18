#!/usr/bin/env bash
set -euo pipefail

# Pinned, reproducible, LGPL-only FFmpeg toolchain for unified native-rate media
# processing. It builds static arm64 ffmpeg and ffprobe helpers; SpeechLens links neither.
ffmpeg_version="8.1.2"
ffmpeg_sha256="464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c"
lame_version="3.100"
lame_sha256="ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e"
runtime_revision="ffmpeg-cli-${ffmpeg_version}-lame-${lame_version}-macos14-arm64-v14-direct-apple-aac"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "${script_dir}/.." && pwd)"
runtime_root="${SPEECHLENS_FFMPEG_RUNTIME_ROOT:-${project_root}/.build/ffmpeg-runtime}"
download_dir="${runtime_root}/downloads"
install_dir="${runtime_root}/installed"
manifest_path="${install_dir}/SPEECHLENS-FFMPEG.txt"

has_component() {
  local executable="$1"
  local component="$2"
  local name="$3"
  "${executable}" -hide_banner -"${component}" 2>/dev/null \
    | awk -v name="$name" '$2 == name { found=1 } END { exit !found }'
}

installed_runtime_is_valid() {
  [[ -x "${install_dir}/ffmpeg" ]] || return 1
  [[ -x "${install_dir}/ffprobe" ]] || return 1
  [[ -f "$manifest_path" ]] || return 1
  grep -Fqx "revision=${runtime_revision}" "$manifest_path" || return 1
  grep -Fqx "source_patches=none" "$manifest_path" || return 1
  local ffmpeg_version_output
  local ffprobe_version_output
  local ffmpeg_version_line
  local ffprobe_version_line
  ffmpeg_version_output="$("${install_dir}/ffmpeg" -version 2>/dev/null)" || return 1
  ffprobe_version_output="$("${install_dir}/ffprobe" -version 2>/dev/null)" || return 1
  ffmpeg_version_line="${ffmpeg_version_output%%$'\n'*}"
  ffprobe_version_line="${ffprobe_version_output%%$'\n'*}"
  [[ "$ffmpeg_version_line" == "ffmpeg version ${ffmpeg_version}"* ]] || return 1
  [[ "$ffprobe_version_line" == "ffprobe version ${ffmpeg_version}"* ]] || return 1
  [[ "$(lipo -archs "${install_dir}/ffmpeg")" == "arm64" ]] || return 1
  [[ "$(lipo -archs "${install_dir}/ffprobe")" == "arm64" ]] || return 1
  for encoder in aac_at alac libmp3lame mpeg4 flac pcm_f32le pcm_f32be pcm_s24le; do
    "${install_dir}/ffmpeg" -hide_banner -encoders 2>/dev/null \
      | grep -E "[[:space:]]${encoder}[[:space:]]" >/dev/null || return 1
  done
  for forbidden_decoder in aac aac_fixed aac_latm aac_at; do
    ! has_component "${install_dir}/ffmpeg" decoders "$forbidden_decoder" || return 1
  done
  ! has_component "${install_dir}/ffmpeg" encoders aac || return 1
  "${install_dir}/ffmpeg" -hide_banner -buildconf 2>/dev/null \
    | grep -F -- "--enable-parser=aac" >/dev/null || return 1
  for demuxer in wav aiff caf avi mov mp3 flac f32le rawvideo; do
    "${install_dir}/ffmpeg" -hide_banner -demuxers 2>/dev/null \
      | grep -E "[[:space:]]${demuxer}([[:space:]]|,)" >/dev/null || return 1
  done
  for muxer in wav aiff caf avi mov mp4 mp3 flac; do
    "${install_dir}/ffmpeg" -hide_banner -muxers 2>/dev/null \
      | grep -E "[[:space:]]${muxer}([[:space:]]|,)" >/dev/null || return 1
  done
}

if installed_runtime_is_valid; then
  echo "SpeechLens FFmpeg tools are ready: ${install_dir}"
  exit 0
fi

mkdir -p "$download_dir" "$runtime_root"
archive="${download_dir}/ffmpeg-${ffmpeg_version}.tar.xz"
if [[ ! -f "$archive" ]]; then
  curl -fL --retry 3 \
    --output "${archive}.partial" \
    "https://ffmpeg.org/releases/ffmpeg-${ffmpeg_version}.tar.xz"
  mv "${archive}.partial" "$archive"
fi

lame_archive="${download_dir}/lame-${lame_version}.tar.gz"
if [[ ! -f "$lame_archive" ]]; then
  curl -fL --retry 3 \
    --output "${lame_archive}.partial" \
    "https://downloads.sourceforge.net/project/lame/lame/${lame_version}/lame-${lame_version}.tar.gz"
  mv "${lame_archive}.partial" "$lame_archive"
fi

actual_sha256="$(shasum -a 256 "$archive" | awk '{print $1}')"
if [[ "$actual_sha256" != "$ffmpeg_sha256" ]]; then
  echo "FFmpeg checksum mismatch: expected ${ffmpeg_sha256}, got ${actual_sha256}" >&2
  exit 1
fi
lame_actual_sha256="$(shasum -a 256 "$lame_archive" | awk '{print $1}')"
if [[ "$lame_actual_sha256" != "$lame_sha256" ]]; then
  echo "LAME checksum mismatch: expected ${lame_sha256}, got ${lame_actual_sha256}" >&2
  exit 1
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/speechlens-ffmpeg.XXXXXX")"
staging_dir="${runtime_root}/installed.staging.$$"
cleanup() {
  local status=$?
  if [[ -d "$work_dir" ]]; then
    find "$work_dir" -depth -delete
  fi
  if [[ -d "$staging_dir" ]]; then
    find "$staging_dir" -depth -delete
  fi
  return "$status"
}
trap cleanup EXIT

mkdir -p "$staging_dir"
tar -xJf "$archive" -C "$work_dir"
tar -xzf "$lame_archive" -C "$work_dir"

deployment_target="14.0"
lame_prefix="${work_dir}/lame-install"
configure_flags=(
  "--prefix=/"
  "--arch=arm64"
  "--target-os=darwin"
  "--cc=clang"
  "--enable-static"
  "--disable-shared"
  "--disable-autodetect"
  "--disable-doc"
  "--disable-debug"
  "--disable-network"
  "--disable-avdevice"
  "--disable-swscale"
  "--disable-encoder=aac"
  "--disable-decoder=aac"
  "--disable-decoder=aac_fixed"
  "--disable-decoder=aac_latm"
  "--disable-decoder=aac_at"
  "--enable-parser=aac"
  "--enable-audiotoolbox"
  "--enable-libmp3lame"
  "--enable-zlib"
  "--disable-protocols"
  "--enable-protocol=file"
  "--enable-protocol=pipe"
  "--pkg-config-flags=--static"
  "--extra-cflags=-O2 -mmacosx-version-min=${deployment_target} -I${lame_prefix}/include"
  "--extra-ldflags=-mmacosx-version-min=${deployment_target} -L${lame_prefix}/lib"
)

build_log="${staging_dir}/build.log"
build_jobs="$(sysctl -n hw.logicalcpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
echo "Building pinned LAME ${lame_version} and FFmpeg ${ffmpeg_version} tools..."
(
  cd "${work_dir}/lame-${lame_version}"
  MACOSX_DEPLOYMENT_TARGET="$deployment_target" ./configure \
    --prefix="$lame_prefix" \
    --disable-shared \
    --enable-static \
    --disable-frontend \
    --disable-decoder \
    CFLAGS="-O2 -mmacosx-version-min=${deployment_target}" \
    LDFLAGS="-mmacosx-version-min=${deployment_target}"
  make -j"$build_jobs"
  make install

  cd "${work_dir}/ffmpeg-${ffmpeg_version}"
  PKG_CONFIG_PATH="${lame_prefix}/lib/pkgconfig" \
    PKG_CONFIG_LIBDIR="${lame_prefix}/lib/pkgconfig" \
    MACOSX_DEPLOYMENT_TARGET="$deployment_target" ./configure "${configure_flags[@]}" &&
    make -j"$build_jobs" ffmpeg ffprobe &&
    cp ffmpeg ffprobe "${staging_dir}/"
) > "$build_log" 2>&1 || {
  tail -n 100 "$build_log" >&2
  exit 1
}

if grep -Fq "WARNING: Option" "$build_log"; then
  echo "FFmpeg configure ignored a requested component:" >&2
  grep -F "WARNING: Option" "$build_log" >&2
  exit 1
fi

chmod 755 "${staging_dir}/ffmpeg" "${staging_dir}/ffprobe"
cp "${work_dir}/ffmpeg-${ffmpeg_version}/COPYING.LGPLv2.1" \
  "${staging_dir}/FFMPEG-LGPL-2.1.txt"
cp "${work_dir}/lame-${lame_version}/COPYING" \
  "${staging_dir}/LAME-LGPL-2.0.txt"

for helper in ffmpeg ffprobe; do
  while IFS= read -r dependency; do
    case "$dependency" in
      /System/Library/*|/usr/lib/*) ;;
      *)
      echo "Unexpected ${helper} dynamic dependency: ${dependency}" >&2
      exit 1
      ;;
    esac
  done < <(otool -L "${staging_dir}/${helper}" | awk 'NR > 1 { print $1 }')
  if [[ "$(lipo -archs "${staging_dir}/${helper}")" != "arm64" ]]; then
    echo "${helper} must be arm64-only" >&2
    exit 1
  fi
  minimum_macos="$(otool -l "${staging_dir}/${helper}" | awk '
    /LC_BUILD_VERSION/ { found=1 }
    found && /minos/ { print $2; exit }
  ')"
  if [[ "$minimum_macos" != "$deployment_target" ]]; then
    echo "Unexpected ${helper} minimum macOS version: ${minimum_macos:-missing}" >&2
    exit 1
  fi
done
if ! "${staging_dir}/ffmpeg" -hide_banner -encoders 2>/dev/null \
  | grep -F "libmp3lame" >/dev/null; then
  echo "FFmpeg helper is missing the libmp3lame encoder" >&2
  exit 1
fi
for encoder in aac_at mpeg4; do
  if ! "${staging_dir}/ffmpeg" -hide_banner -encoders 2>/dev/null \
    | grep -E "[[:space:]]${encoder}[[:space:]]" >/dev/null; then
    echo "FFmpeg helper is missing the ${encoder} encoder" >&2
    exit 1
  fi
done
if has_component "${staging_dir}/ffmpeg" encoders aac; then
  echo "FFmpeg helper unexpectedly includes the native AAC encoder" >&2
  exit 1
fi
for decoder in aac aac_fixed aac_latm aac_at; do
  if has_component "${staging_dir}/ffmpeg" decoders "$decoder"; then
    echo "FFmpeg helper unexpectedly includes the ${decoder} decoder" >&2
    exit 1
  fi
done
if ! grep -Fqx '#define CONFIG_AAC_PARSER 1' \
  "${work_dir}/ffmpeg-${ffmpeg_version}/config_components.h"; then
  echo "FFmpeg helper is missing the AAC parser required for packet copying" >&2
  exit 1
fi
for encoder in pcm_f32le pcm_f32be pcm_s24le; do
  if ! "${staging_dir}/ffmpeg" -hide_banner -encoders 2>/dev/null \
    | grep -E "[[:space:]]${encoder}[[:space:]]" >/dev/null; then
    echo "FFmpeg helper is missing the ${encoder} encoder" >&2
    exit 1
  fi
done
for decoder in mp3 png mjpeg; do
  if ! "${staging_dir}/ffmpeg" -hide_banner -decoders 2>/dev/null \
    | grep -E "[[:space:]]${decoder}[[:space:]]" >/dev/null; then
    echo "FFmpeg helper is missing the ${decoder} decoder" >&2
    exit 1
  fi
done
for component in encoder decoder; do
  if ! "${staging_dir}/ffmpeg" -hide_banner -"${component}s" 2>/dev/null \
    | grep -E '[[:space:]]flac[[:space:]]' >/dev/null; then
    echo "FFmpeg helper is missing the native FLAC ${component}" >&2
    exit 1
  fi
done
for component in demuxer muxer; do
  if ! "${staging_dir}/ffmpeg" -hide_banner -"${component}s" 2>/dev/null \
    | grep -E '[[:space:]]flac[[:space:]]' >/dev/null; then
    echo "FFmpeg helper is missing the FLAC ${component}" >&2
    exit 1
  fi
done
if ! "${staging_dir}/ffmpeg" -hide_banner -demuxers 2>/dev/null \
  | grep -E '[[:space:]]mov([[:space:]]|,)' >/dev/null; then
  echo "FFmpeg helper is missing MOV/M4A demuxing" >&2
  exit 1
fi
if ! "${staging_dir}/ffmpeg" -hide_banner -demuxers 2>/dev/null \
  | grep -E '[[:space:]]f32le[[:space:]]' >/dev/null; then
  echo "FFmpeg helper is missing raw Float32 PCM demuxing" >&2
  exit 1
fi
if ! "${staging_dir}/ffmpeg" -hide_banner -demuxers 2>/dev/null \
  | grep -E '[[:space:]]mp3[[:space:]]' >/dev/null; then
  echo "FFmpeg helper is missing MP3 demuxing" >&2
  exit 1
fi
if ! "${staging_dir}/ffmpeg" -hide_banner -muxers 2>/dev/null \
  | grep -E '[[:space:]]mp3[[:space:]]' >/dev/null; then
  echo "FFmpeg helper is missing the MP3 muxer" >&2
  exit 1
fi
for demuxer in wav aiff caf avi mov mp3 flac f32le rawvideo; do
  if ! "${staging_dir}/ffmpeg" -hide_banner -demuxers 2>/dev/null \
    | grep -E "[[:space:]]${demuxer}([[:space:]]|,)" >/dev/null; then
    echo "FFmpeg helper is missing the ${demuxer} demuxer" >&2
    exit 1
  fi
done
for muxer in wav aiff caf avi mov mp4 mp3 flac; do
  if ! "${staging_dir}/ffmpeg" -hide_banner -muxers 2>/dev/null \
    | grep -E "[[:space:]]${muxer}([[:space:]]|,)" >/dev/null; then
    echo "FFmpeg helper is missing the ${muxer} muxer" >&2
    exit 1
  fi
done
if grep -E '^#define CONFIG_(GPL|NONFREE) 1$' \
  "${work_dir}/ffmpeg-${ffmpeg_version}/config.h" >/dev/null; then
  echo "FFmpeg helper unexpectedly enabled GPL or nonfree mode" >&2
  exit 1
fi

configure_manifest="${configure_flags[*]}"
configure_manifest="${configure_manifest//$lame_prefix/<LAME_PREFIX>}"

{
  echo "revision=${runtime_revision}"
  echo "ffmpeg_version=${ffmpeg_version}"
  echo "ffmpeg_sha256=${ffmpeg_sha256}"
  echo "source_url=https://ffmpeg.org/releases/ffmpeg-${ffmpeg_version}.tar.xz"
  echo "source_patches=none"
  echo "lame_version=${lame_version}"
  echo "lame_sha256=${lame_sha256}"
  echo "lame_source_url=https://downloads.sourceforge.net/project/lame/lame/${lame_version}/lame-${lame_version}.tar.gz"
  echo "architecture=arm64"
  echo "deployment_target=${deployment_target}"
  echo "license=LGPL-2.1-or-later AND LGPL-2.0-or-later"
  echo "ffmpeg_license=LGPL-2.1-or-later"
  echo "lame_license=LGPL-2.0-or-later"
  echo "configure=${configure_manifest}"
} > "${staging_dir}/SPEECHLENS-FFMPEG.txt"

if [[ -d "$install_dir" ]]; then
  find "$install_dir" -depth -delete
fi
mv "$staging_dir" "$install_dir"

echo "SpeechLens FFmpeg tools built at: ${install_dir}"
