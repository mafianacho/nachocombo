# Sourced by build.sh and the privacy scripts. ffmpeg and ffprobe run from a pinned public Docker image because the
# Playwright-bundled ffmpeg has no H.264 encoder. Nothing is installed on the host and every container is --rm.
#   FFMPEG_IMAGE        image reference (default: jrottenberg/ffmpeg 7-ubuntu, pinned by digest)
#   FFMPEG_MODE=local   use ffmpeg / ffprobe from PATH instead (must include libx264, palettegen, tile, drawtext)
#   FFMPEG_DOCKER_USER  set to "$(id -u):$(id -g)" on a rootful Docker so output files are not owned by root
#                       (leave unset on rootless Docker: the container's root already is you)
#   DOCKER_HOST         e.g. unix:///run/user/<uid>/docker.sock for rootless Docker
FFMPEG_IMAGE="${FFMPEG_IMAGE:-jrottenberg/ffmpeg@sha256:292a972c60356abd651d9a4f9c808c13e7473f65ad400b7eb99215f4e571931d}"

# _ffrun <tool> <mount dir> [--font-dir <dir>] args...   (paths in args are relative to the mount dir)
_ffrun() {
  local tool="$1" dir="$2"; shift 2
  local fontdir=""
  if [ "${1:-}" = "--font-dir" ]; then fontdir="$2"; shift 2; fi
  if [ "${FFMPEG_MODE:-docker}" = "local" ]; then
    (cd "$dir" && "$tool" -hide_banner "$@")
  else
    local extra=()
    [ -n "$fontdir" ] && extra+=(-v "$fontdir":/fonts:ro)
    [ -n "${FFMPEG_DOCKER_USER:-}" ] && extra+=(-u "$FFMPEG_DOCKER_USER")
    docker run --rm "${extra[@]}" -v "$dir":/w -w /w --entrypoint "$tool" "$FFMPEG_IMAGE" -hide_banner "$@"
  fi
}
ff() { _ffrun ffmpeg "$@"; }
fp() { _ffrun ffprobe "$@"; }
