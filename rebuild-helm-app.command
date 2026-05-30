#!/bin/zsh
set -euo pipefail

APP_NAME="Helm"
LEGACY_APP_NAME="HAM"
BUNDLE_IDENTIFIER="dev.deng.helm"
REMOTE="${HELM_REMOTE:-origin}"
BRANCH="${HELM_BRANCH:-main}"
CONFIGURATION="${HELM_CONFIGURATION:-Release}"
INSTALL_DIR="${HELM_INSTALL_DIR:-/Applications}"

SCRIPT_PATH="${0:A}"
REPO_DIR="${SCRIPT_PATH:h}"
BUILD_ROOT="$REPO_DIR/build"
RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
RUN_WORK_DIR="${TMPDIR:-/tmp}/helm-rebuild-$RUN_ID"
DERIVED_DATA_PATH="$RUN_WORK_DIR/DerivedData"
PACKAGE_DIR="$RUN_WORK_DIR/Package"
PACKAGED_APP="$PACKAGE_DIR/$APP_NAME.app"
INSTALL_APP="$INSTALL_DIR/$APP_NAME.app"
LOG_DIR="$BUILD_ROOT/logs"
LOG_FILE="$LOG_DIR/rebuild-helm-app-$RUN_ID.log"
BUILD_WORKTREE=""
SOURCE_DIR=""

mkdir -p "$LOG_DIR" "$PACKAGE_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

log() {
  printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

die() {
  log "ERROR: $*"
  exit 1
}

cleanup() {
  local exit_code=$?

  if [[ -n "${BUILD_WORKTREE:-}" && -e "$BUILD_WORKTREE" ]]; then
    log "Removing temporary worktree: $BUILD_WORKTREE"
    git -C "$REPO_DIR" worktree remove --force "$BUILD_WORKTREE" >/dev/null 2>&1 || rm -rf "$BUILD_WORKTREE"
  fi

  if [[ "${HELM_KEEP_BUILD_ARTIFACTS:-0}" != "1" && -n "${RUN_WORK_DIR:-}" && -e "$RUN_WORK_DIR" ]]; then
    rm -rf "$RUN_WORK_DIR" >/dev/null 2>&1 || true
  fi

  if (( exit_code == 0 )); then
    log "Done. Log saved to: $LOG_FILE"
  else
    log "Failed. Log saved to: $LOG_FILE"
  fi
}
trap cleanup EXIT

run() {
  log "+ $*"
  "$@"
}

xcodebuild_run() {
  local args=()

  if [[ "${HELM_XCODEBUILD_VERBOSE:-0}" != "1" ]]; then
    args=(-quiet)
  fi

  run xcodebuild "${args[@]}" "$@"
}

ensure_full_xcode() {
  if xcodebuild -version >/dev/null 2>&1; then
    return
  fi

  local candidate
  for candidate in /Applications/Xcode.app /Applications/Xcode-beta.app; do
    if [[ -x "$candidate/Contents/Developer/usr/bin/xcodebuild" ]]; then
      export DEVELOPER_DIR="$candidate/Contents/Developer"
      log "Using Xcode at: $candidate"
      xcodebuild -version >/dev/null 2>&1 || die "Xcode was found but xcodebuild is not usable."
      return
    fi
  done

  die "A full Xcode installation is required. Install Xcode or set DEVELOPER_DIR, then run this again."
}

status_is_clean_except_this_script() {
  local self_rel="${SCRIPT_PATH#$REPO_DIR/}"
  local line status_path

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    status_path="${line[4,-1]}"

    if [[ "$status_path" == "$self_rel" ]]; then
      continue
    fi

    return 1
  done < <(git -C "$REPO_DIR" status --porcelain --untracked-files=all)

  return 0
}

prepare_source_tree() {
  run git -C "$REPO_DIR" rev-parse --is-inside-work-tree >/dev/null

  log "Fetching latest $REMOTE/$BRANCH."
  run git -C "$REPO_DIR" fetch --prune "$REMOTE" "+refs/heads/${BRANCH}:refs/remotes/${REMOTE}/${BRANCH}"

  local current_branch
  current_branch="$(git -C "$REPO_DIR" branch --show-current || true)"

  if [[ "$current_branch" == "$BRANCH" ]] && status_is_clean_except_this_script; then
    log "Updating local $BRANCH with a fast-forward merge."
    run git -C "$REPO_DIR" merge --ff-only "$REMOTE/$BRANCH"
    SOURCE_DIR="$REPO_DIR"
    return
  fi

  log "Current checkout is not a clean $BRANCH branch, so the app will be built from a temporary $REMOTE/$BRANCH worktree."
  BUILD_WORKTREE="$(mktemp -d "${TMPDIR:-/tmp}/helm-main.XXXXXX")"
  rmdir "$BUILD_WORKTREE"
  run git -C "$REPO_DIR" worktree add --detach "$BUILD_WORKTREE" "$REMOTE/$BRANCH"
  SOURCE_DIR="$BUILD_WORKTREE"
}

build_app() {
  [[ -n "$SOURCE_DIR" ]] || die "Source tree was not prepared."
  [[ -d "$SOURCE_DIR/Helm.xcodeproj" ]] || die "Missing Helm.xcodeproj in $SOURCE_DIR."

  rm -rf "$PACKAGE_DIR"
  mkdir -p "$PACKAGE_DIR"

  log "Resolving Swift packages."
  xcodebuild_run \
    -project "$SOURCE_DIR/Helm.xcodeproj" \
    -scheme "$APP_NAME" \
    -resolvePackageDependencies

  log "Building $APP_NAME.app ($CONFIGURATION)."
  xcodebuild_run \
    -project "$SOURCE_DIR/Helm.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration "$CONFIGURATION" \
    -destination "platform=macOS" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    CODE_SIGN_IDENTITY="-" \
    clean build

  local built_app="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME.app"
  [[ -d "$built_app" ]] || die "Build completed, but app bundle was not found at $built_app."

  log "Staging app bundle: $PACKAGED_APP"
  run ditto "$built_app" "$PACKAGED_APP"
}

quit_running_apps() {
  local name

  for name in "$APP_NAME" "$LEGACY_APP_NAME"; do
    if pgrep -x "$name" >/dev/null 2>&1; then
      osascript -e "tell application \"$name\" to quit" >/dev/null 2>&1 || true
    fi
  done

  sleep 1

  for name in "$APP_NAME" "$LEGACY_APP_NAME"; do
    if pgrep -x "$name" >/dev/null 2>&1; then
      log "Stopping running app process: $name"
      pkill -x "$name" >/dev/null 2>&1 || true
    fi
  done
}

launch_services_tool() {
  printf '%s\n' "/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"
}

is_target_app() {
  local app_path="$1"
  local base_name="${app_path:t}"
  local bundle_id=""

  if [[ -f "$app_path/Contents/Info.plist" ]]; then
    bundle_id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$app_path/Contents/Info.plist" 2>/dev/null || true)"
  fi

  [[ "$bundle_id" == "$BUNDLE_IDENTIFIER" || "$base_name" == "$APP_NAME.app" || "$base_name" == "$LEGACY_APP_NAME.app" ]]
}

list_old_apps() {
  local root depth app_path

  while IFS=$'\t' read -r root depth; do
    [[ -d "$root" ]] || continue

    while IFS= read -r app_path; do
      is_target_app "$app_path" && printf '%s\n' "$app_path"
    done < <(find "$root" -maxdepth "$depth" -type d -name "*.app" -prune -print 2>/dev/null || true)
  done <<EOF
$INSTALL_DIR	2
$HOME/Applications	5
$HOME/Desktop	5
$HOME/Downloads	8
$HOME/Library/Developer/Xcode/DerivedData	8
$REPO_DIR/build	8
EOF
}

unregister_app() {
  local app_path="$1"
  local lsregister

  lsregister="$(launch_services_tool)"
  if [[ -x "$lsregister" ]]; then
    "$lsregister" -u "$app_path" >/dev/null 2>&1 || true
  fi
}

register_installed_app() {
  local lsregister

  lsregister="$(launch_services_tool)"
  if [[ -x "$lsregister" && -d "$INSTALL_APP" ]]; then
    "$lsregister" -f -R -trusted "$INSTALL_APP" >/dev/null 2>&1 || true
  fi
}

move_app_to_trash() {
  local app_path="$1"
  local base_name="${app_path:t}"
  local base_without_ext="${base_name%.app}"
  local trash_path="$HOME/.Trash/$base_without_ext-$(date +%Y%m%d-%H%M%S)-$RANDOM.app"

  mkdir -p "$HOME/.Trash"
  unregister_app "$app_path"

  if mv "$app_path" "$trash_path" 2>/dev/null; then
    log "Moved old app to Trash: $app_path"
    return
  fi

  if [[ "$app_path" == "$INSTALL_APP" ]]; then
    die "Could not move existing installed app to Trash: $app_path"
  fi

  log "WARNING: Could not move old app to Trash, continuing: $app_path"
}

remove_old_apps() {
  if [[ "${HELM_SKIP_APP_REMOVAL:-0}" == "1" ]]; then
    log "Skipping old app removal because HELM_SKIP_APP_REMOVAL=1."
    return
  fi

  local app_path
  typeset -A seen

  while IFS= read -r app_path; do
    [[ -z "$app_path" ]] && continue
    [[ -n "${BUILD_WORKTREE:-}" && "$app_path" == "$BUILD_WORKTREE/"* ]] && continue
    [[ "$app_path" == "$RUN_WORK_DIR/"* ]] && continue
    [[ -n "${seen[$app_path]:-}" ]] && continue
    seen[$app_path]=1
    move_app_to_trash "$app_path"
  done < <(list_old_apps)
}

install_packaged_app() {
  if [[ "${HELM_SKIP_INSTALL:-0}" == "1" ]]; then
    log "Skipping install because HELM_SKIP_INSTALL=1."
    return
  fi

  [[ -d "$PACKAGED_APP" ]] || die "Packaged app is missing: $PACKAGED_APP"

  if [[ ! -d "$INSTALL_DIR" ]]; then
    run sudo mkdir -p "$INSTALL_DIR"
  fi

  log "Installing new app to: $INSTALL_APP"
  if ditto "$PACKAGED_APP" "$INSTALL_APP" 2>/dev/null; then
    :
  else
    log "Need elevated permission to install into $INSTALL_DIR."
    run sudo ditto "$PACKAGED_APP" "$INSTALL_APP"
  fi

  register_installed_app

  if [[ "${HELM_REVEAL_APP:-1}" == "1" ]]; then
    open -R "$INSTALL_APP" >/dev/null 2>&1 || true
  fi
}

main() {
  log "Rebuild $APP_NAME.app from $REMOTE/$BRANCH."
  log "Repository: $REPO_DIR"

  ensure_full_xcode
  prepare_source_tree
  build_app
  quit_running_apps
  remove_old_apps
  install_packaged_app

  if [[ "${HELM_SKIP_INSTALL:-0}" == "1" ]]; then
    if [[ "${HELM_KEEP_BUILD_ARTIFACTS:-0}" == "1" ]]; then
      log "Install skipped. Staged copy: $PACKAGED_APP"
    else
      log "Install skipped. Temporary staged copy will be removed."
    fi
    return
  fi

  log "Installed app: $INSTALL_APP"
}

main "$@"
