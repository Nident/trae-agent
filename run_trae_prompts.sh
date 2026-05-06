#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"

[ -f "$ENV_FILE" ] || {
  echo "Env file not found: $ENV_FILE" >&2
  exit 1
}

# shellcheck source=/dev/null
source "$ENV_FILE"

PROMPT_DIR="${PROMPT_DIR:-${PROMPTS_DIR:-}}"
PYTHON_BIN="${PYTHON_BIN:-python}"
GIT_BASE_URL="${GIT_BASE_URL:-https://github.com}"
WORK_ROOT="${WORK_ROOT:-$HOME/trae_work}"
OUTPUT_DIR="${OUTPUT_DIR:-$HOME/secure_answers}"
LOG_FILE="${LOG_FILE:-$HOME/trae_run.log}"
TRAE_BIN="${TRAE_BIN:-trae-cli}"
TRAE_CONFIG_FILE="${TRAE_CONFIG_FILE:-${CONFIG_FILE:-}}"
TRAE_CONSOLE_TYPE="${TRAE_CONSOLE_TYPE:-simple}"
TRAE_LIVE_LOG="${TRAE_LIVE_LOG:-true}"
LOG_TAIL_LINES="${LOG_TAIL_LINES:-80}"
CLEAN_EXTRA_PATHS="${CLEAN_EXTRA_PATHS:-.git .hg .svn .bzr .github .gitlab .circleci .travis.yml .gitmodules .gitignore .gitattributes}"

mkdir -p "$WORK_ROOT" "$OUTPUT_DIR"

log() {
  echo "$*" | tee -a "$LOG_FILE"
}

safe_name() {
  local value="$1"
  value="${value//\//__}"
  printf '%s' "$value" | tr -c 'A-Za-z0-9._-' '_'
}

read_yaml() {
  local yaml_file="$1"
  local prompt_file="$2"
  local meta_file="$3"

  "$PYTHON_BIN" - "$yaml_file" "$prompt_file" > "$meta_file" <<'PY'
import shlex
import sys
from pathlib import Path

import yaml

yaml_file = Path(sys.argv[1])
prompt_file = Path(sys.argv[2])

data = yaml.safe_load(yaml_file.read_text(encoding="utf-8")) or {}

idx = str(data["idx"])
project = str(data["project"])
language = str(data["language"])
commit = str(data["checked_commit"])
prompt = str(data["prompt"])

prompt_file.write_text(prompt, encoding="utf-8")

for name, value in {
    "IDX": idx,
    "PROJECT": project,
    "LANGUAGE": language,
    "COMMIT": commit,
}.items():
    print(f"{name}={shlex.quote(value)}")
PY
}

clean_repo() {
  local repo_dir="$1"
  local path

  find "$repo_dir" \( -name .git -o -name .hg -o -name .svn -o -name .bzr \) -prune -exec rm -rf -- {} +

  for path in $CLEAN_EXTRA_PATHS; do
    path="${path#/}"
    [ -n "$path" ] && rm -rf -- "$repo_dir/$path"
  done

  find "$repo_dir" -type f \( -name 'answer_*.json' -o -name '*.patch' -o -name '*.diff' \) -delete
}

run_trae() {
  local repo_dir="$1"
  local prompt_file="$2"
  local -a cmd
  local rc

  cmd=("$TRAE_BIN" run -f "$prompt_file" --working-dir "$repo_dir" --console-type "$TRAE_CONSOLE_TYPE")

  if [ -n "$TRAE_CONFIG_FILE" ]; then
    cmd+=(--config-file "$TRAE_CONFIG_FILE")
  fi

  log "[debug] repo_dir=$repo_dir"
  log "[debug] prompt_file=$prompt_file"
  log "[debug] config_file=${TRAE_CONFIG_FILE:-<default>}"
  {
    printf '[debug] command:'
    printf ' %q' "${cmd[@]}"
    printf '\n'
  } | tee -a "$LOG_FILE"

  (
    cd "$repo_dir"
    set +e
    if [ "$TRAE_LIVE_LOG" = "true" ]; then
      "${cmd[@]}" 2>&1 | tee -a "$LOG_FILE"
      rc=${PIPESTATUS[0]}
    else
      "${cmd[@]}" >> "$LOG_FILE" 2>&1
      rc=$?
    fi
    exit "$rc"
  )
}

debug_missing_answer() {
  local task_dir="$1"

  log "[debug] No answer_*.json found. Files under task dir:"
  find "$task_dir" -maxdepth 4 -type f | sort | sed 's/^/[debug] file: /' | tee -a "$LOG_FILE" || true

  log "[debug] Last $LOG_TAIL_LINES log lines:"
  tail -n "$LOG_TAIL_LINES" "$LOG_FILE" | sed 's/^/[log-tail] /' || true
}

move_answer() {
  local task_dir="$1"
  local repo_dir="$2"
  local output_file="$3"
  local answer_file="$repo_dir/answer_${COMMIT}.json"

  if [ ! -f "$answer_file" ]; then
    answer_file="$(find "$task_dir" -type f -name 'answer_*.json' | head -n 1 || true)"
  fi

  if [ -z "$answer_file" ] || [ ! -f "$answer_file" ]; then
    log "[!] Answer not found for $PROJECT $COMMIT"
    debug_missing_answer "$task_dir"
    return 1
  fi

  if [ -f "$output_file" ]; then
    output_file="${output_file%.json}_$(date +%s).json"
  fi

  mv "$answer_file" "$output_file"
  log "[+] Saved: $output_file"
}

[ -n "$PROMPT_DIR" ] || {
  echo "PROMPT_DIR is not set" >&2
  exit 1
}

echo "=== START $(date) ===" >> "$LOG_FILE"

for fn in "$PROMPT_DIR"/*.yaml; do
  [ -e "$fn" ] || continue

  task_dir="$(mktemp -d "$WORK_ROOT/task.XXXXXX")"
  repo_dir="$task_dir/repo"
  prompt_file="$task_dir/prompt.txt"
  meta_file="$task_dir/meta.env"

  log "[+] Processing: $fn"

  if ! read_yaml "$fn" "$prompt_file" "$meta_file"; then
    log "[x] YAML read failed: $fn"
    rm -rf "$task_dir"
    continue
  fi

  # shellcheck source=/dev/null
  source "$meta_file"

  project_safe="$(safe_name "$PROJECT")"
  language_safe="$(safe_name "$LANGUAGE")"
  output_file="$OUTPUT_DIR/${IDX}_${project_safe}_${language_safe}_${COMMIT}.json"
  repo_url="${GIT_BASE_URL%/}/$PROJECT.git"

  log "[+] git clone: $repo_url"
  if ! git clone --quiet --no-checkout "$repo_url" "$repo_dir" >> "$LOG_FILE" 2>&1; then
    log "[x] Clone failed: $PROJECT"
    rm -rf "$task_dir"
    continue
  fi

  log "[+] git checkout: $COMMIT"
  if ! git -C "$repo_dir" checkout --quiet --detach "$COMMIT" >> "$LOG_FILE" 2>&1; then
    log "[x] Checkout failed: $PROJECT $COMMIT"
    rm -rf "$task_dir"
    continue
  fi

  clean_repo "$repo_dir"

  log "[+] Running trae-cli"
  if run_trae "$repo_dir" "$prompt_file"; then
    if move_answer "$task_dir" "$repo_dir" "$output_file"; then
      log "[+] Success: $fn"
    else
      log "[x] Failed: answer file was not created for $fn"
    fi
  else
    log "[x] Failed: $fn"
  fi

  rm -rf "$task_dir"
done

echo "=== DONE $(date) ===" >> "$LOG_FILE"
