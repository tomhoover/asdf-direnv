#!/usr/bin/env bash

if [ -n "$ASDF_DIRENV_DEBUG" ]; then
  set -x
fi

# Load direnv stdlib if not already loaded
if [ -z "$direnv" ] && [ -z "$(declare -f -F watch_file)" ]; then
  # We need to eval direnv stdlib, but before doing so
  # we need to determine which direnv executable we should use.
  #
  # The fastest way is a user specified $ASDF_DIRENV_BIN.
  #
  # Otherwise if we find direnv in PATH, we use that.
  #
  # Otherwise - but a bit slow path - we ask asdf to resolve direnv.
  #
  # If all of this fails, we inform the users with an error.
  #
  direnv="${ASDF_DIRENV_BIN}"

  if [ -z "$direnv" ]; then
    direnv="$(command -v direnv || true)" # prevent exit on failure
  fi

  if [ -z "$direnv" ]; then
    direnv="$(asdf which direnv 2>/dev/null || true)" # prevent exit on failure
  fi

  if [ -z "$direnv" ]; then
    cat <<-'EOF' >&2
No direnv executable found. Please do one of the following:

With a system installed direnv

    export ASDF_DIRENV_BIN="$(command -v direnv)"

With an asdf installed direnv

    export ASDF_DIRENV_BIN="$(asdf which direnv)"
EOF
    exit 1
  fi

  eval "$("$direnv" stdlib)"
fi

# This is inspired by https://stackoverflow.com/a/1116890
_follow_symlink() {
  path="$1"

  # Start in the directory of the (possible) symlink.
  cd "$(dirname "$path")" || return 1
  filename="$(basename "$path")"

  # Follow symlinks until we run out of symlinks.
  # This probably will loop forever if there's a cycle.
  while [ -L "$path" ]; do
    path="$(readlink "$filename")"
    cd "$(dirname "$path")" || return 1
    filename="$(basename "$path")"
  done

  # Now print out the final directory we ended up in, plus the final filename.
  echo "$(pwd -P)/$filename"
}

_load_asdf_utils() {
  if [ -z "$(declare -f -F with_plugin_env)" ]; then
    ASDF_DIR="${ASDF_DIR:-"$(_follow_symlink "$(command -v asdf)" | xargs dirname | xargs dirname)"}"
    # libexec is a Homebrew specific thing. See
    # https://github.com/asdf-community/asdf-direnv/issues/95 for details.
    local lib_file
    lib_file=$(ls "$ASDF_DIR"/{lib,libexec/lib}/utils.bash 2>/dev/null || true)
    if [ ! -f "$lib_file" ]; then
      log_error "Could not find asdf utils.bash file in $ASDF_DIR"
      return 1
    fi
    # shellcheck source=/dev/null # we don't want shellcheck trying to find this file
    source "$lib_file"
  fi
}

_cache_dir() {
  XDG_CACHE_HOME=${XDG_CACHE_HOME:-$HOME/.cache}
  local dir
  dir=$XDG_CACHE_HOME/asdf-direnv
  mkdir -p "$dir"
  echo "$dir"
}

_asdf_cached_envrc() {
  local dump_dir tools_file tools_cksum env_file
  dump_dir="$(_cache_dir)/env"
  generating_dump_dir="$(_cache_dir)/env-generating"
  tools_file="$(_local_versions_file)"
  tools_cksum="$(_cksum "$tools_file" "$ASDF_DIRENV_DEBUG" "$@")"
  env_file="$dump_dir/$tools_cksum"

  if [ -f "$env_file" ] && [ -z "$ASDF_DIRENV_DEBUG" ]; then
    echo "$env_file"
    return 0
  fi

  _load_asdf_utils

  mkdir -p "$dump_dir" "$generating_dump_dir"
  rm "$dump_dir/$(echo "$tools_cksum" | cut -d- -f1-2)"-* 2>/dev/null || true
  log_status "Creating env file $env_file"

  # Write to a temp file first instead of directly to ${env_file} so if we
  # crash while generating the file, we don't leave the (broken) cached file
  # around.
  # We use a randomly chosen filename to allow two different processes to
  # generate this at the same time without stepping on each other's toes.
  generating_env_file="$(mktemp "$generating_dump_dir/$tools_cksum.XXXX")"
  _asdf_envrc "$tools_file" | _no_dups >"${generating_env_file}"
  mv "${generating_env_file}" "${env_file}"

  echo "$env_file"
}

_asdf_envrc() {
  if [ -n "$ASDF_DIRENV_DEBUG" ]; then
    echo 'set -x'
  fi
  local tools_file="$1"
  _load_global_plugins_env "$tools_file"
  _load_local_plugins_env "$tools_file"
}

# compute a checksump to see if we can use the cache or have to compute the environment again
_cksum() {
  local file="$1"
  # working directory, the arguments given to use_asdf, direnv status, and the tools-version modification times.
  # shellcheck disable=SC2154 # var is referenced but not assigned.
  cksum <(pwd) <(echo "$@") <("$direnv" status) <(test -f "$file" && ls -l "$file") | cut -d' ' -f 1 | tr $'\n' '-' | sed -e 's/-$//'
}

_tgrep() {
  # Never failing grep
  grep "$@" || true
}

_tail_r() {
  # portable version of tail -r
  cat -n | sort -nr | cut -f2-
}

_no_dups() {
  awk '!a[$0]++' -
}

_each_do() {
  while IFS=$'\n' read -r line; do
    "$@" "$line"
  done
}

_local_versions_file() {
  local tool_versions
  tool_versions="$(find_up .tool-versions)"
  if [ -f "$tool_versions" ]; then
    echo "$tool_versions"
  elif [ -f "$HOME/.tool-versions" ]; then
    echo "$HOME/.tool-versions"
  fi
}

_plugins_in_file() {
  local tool_versions=$1
  cut -d'#' -f1 "$tool_versions" | cut -d' ' -f1 | awk NF | uniq
}

_all_plugins_list() {
  find "$(get_plugin_path)" -maxdepth 1 -mindepth 1 -exec basename '{}' \;
}

_except_local_plugins_list() {
  local tool_versions=$1
  if [ -f "$tool_versions" ]; then
    _all_plugins_list | _new_items <(_plugins_in_file "$tool_versions")
  else
    _all_plugins_list
  fi
}

_load_global_plugins_env() {
  local tool_versions=$1
  _except_local_plugins_list "$tool_versions" | sort | _tail_r | _each_do _load_plugin_version_and_file
}

_load_local_plugins_env() {
  local tool_versions=$1
  if [ -f "$tool_versions" ]; then
    _plugins_in_file "$tool_versions" | _tail_r | _each_do _load_plugin_version_and_file
  fi
}

# from asdf plugin_current_command
_load_plugin_version_and_file() {
  local plugin_name=$1
  local versions_and_path
  versions_and_path="$(find_versions "$plugin_name" "$(pwd)")"
  if test -z "$versions_and_path"; then
    return 0
  fi

  local path
  path=$(cut -d '|' -f 2 <<<"$versions_and_path")
  local versions=()
  while IFS=$' \t' read -r -a inline_versions; do
    for ((idx = ${#inline_versions[@]} - 1; idx >= 0; idx--)); do
      versions+=("${inline_versions[idx]}")
    done
  done <<<"$(cut -d '|' -f 1 <<<"$versions_and_path" | uniq | _tail_r)"

  for version in "${versions[@]}"; do
    echo log_status "using asdf ${plugin_name} ${version}"
    _plugin_env_bash "$plugin_name" "$version" "$plugin $version not installed. Run 'asdf install' and then 'direnv reload'."
  done
  if [ -f "$path" ]; then
    printf 'watch_file %q\n' "$path"
  fi
}

_new_items() {
  # Output only the lines from STDIN not present in $1 file
  awk 'NR == FNR { a[$0]; next } !($0 in a)' "$1" -
}

_path_changed_entries() {
  local old_path new_path
  old_path="$(echo -n "$1" | tr ':' $'\n')"
  new_path="$(echo -n "$2" | tr ':' $'\n')"
  echo -n "$new_path" | _new_items <(echo -n "$old_path")
}

_direnv_bash_dump() {
  "$direnv" dump bash | sed -e $'s#;export#\\\nexport#g' | sed -e 's#;$##'
}

_plugin_env_bash() {
  local plugin="${1}"
  local full_version="${2}"
  local not_installed_message="${3}"

  # NOTE: unlike asdf, asdf-direnv does not support other installation types.
  local install_type="version"

  plugin_path=$(get_plugin_path "$plugin")
  if [ ! -d "$plugin_path" ]; then
    log_error "asdf plugin not installed: $plugin"
    exit 1
  fi

  local version

  # The full_version may be of the form `latest:X`, so we resolve the latest
  # version here. This is the same method asdf itself uses; see
  # https://github.com/asdf-vm/asdf/blob/7493f4099c844e40af72d7f05635d7991a463d1a/lib/commands/command-install.bash#L161
  IFS=':' read -r -a version_info <<<"$full_version"
  if [ "${version_info[0]}" = "latest" ]; then
    version=$(asdf latest "$plugin_name" "${version_info[1]}")
  else
    version="${version_info[0]}"
  fi

  if [ "$version" != "system" ]; then
    install_path=$(get_install_path "$plugin" "$install_type" "$version")
    if [ ! -d "$install_path" ]; then
      log_error "$not_installed_message"
      exit 1
    fi
  fi

  # If plugin has custom-shims, add them first to they appear last on final PATH
  if [ -d "$plugin_path/shims" ]; then
    echo PATH_add "$plugin_path/shims"
  fi

  # Add plugin bin_paths to PATH. We add them in reverse order to preserve original PATH.
  # NOTE: The plugin returns a list of space-separated dirs relative to install_dir.
  # NOTE: We don't add custom shims into path.
  # NOTE: If install_path is empty (ex. "system" version), skip this step so /bin doesn't get added to PATH.
  if [ -n "$install_path" ]; then
    list_plugin_bin_paths "$plugin_name" "$version" "$install_type" |
      tr $' ' $'\n' | _tail_r | sed -e "s#^#$install_path/#" | _each_do echo PATH_add
  fi

  # If the plugin defines custom environment, source it.
  if [ -f "${plugin_path}/bin/exec-env" ]; then
    echo "ASDF_INSTALL_TYPE='$install_type' ASDF_INSTALL_VERSION='$version' ASDF_INSTALL_PATH='$install_path' source_env ${plugin_path}/bin/exec-env"
  fi
}
