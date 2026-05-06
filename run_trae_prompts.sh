#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="$(basename -- "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

die() {
  log "ERROR: $*"
  exit 1
}

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS]

Runs Trae Agent over YAML prompts, one isolated checkout per prompt.

Options:
  --env-file PATH   Load configuration from PATH instead of ./.env
  --dry-run         Parse prompts and print planned work without cloning/running
  --limit N         Override PROMPTS_LIMIT for this run
  -h, --help        Show this help

Configuration is loaded from the env file. See .env.example.
EOF
}

is_true() {
  case "${1:-}" in
    1 | true | TRUE | yes | YES | y | Y | on | ON) return 0 ;;
    *) return 1 ;;
  esac
}

load_env() {
  [[ -f "$ENV_FILE" ]] || die "Env file not found: $ENV_FILE"

  set +u
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set -u
}

apply_defaults() {
  PYTHON_BIN="${PYTHON_BIN:-python}"
  JQ_BIN="${JQ_BIN:-jq}"

  PROMPTS_DIR="${PROMPTS_DIR:-/Users/nident/Desktop/JOB/ScolTech/vul-awesome-skills/data/generated_prompts}"
  PROMPTS_PATTERN="${PROMPTS_PATTERN:-*.yaml}"
  PROMPTS_MAX_DEPTH="${PROMPTS_MAX_DEPTH:-1}"
  PROMPTS_LIMIT="${PROMPTS_LIMIT:-0}"

  GIT_BASE_URL="${GIT_BASE_URL:-https://github.com}"
  WORK_ROOT="${WORK_ROOT:-$SCRIPT_DIR/work}"
  OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/answers}"
  OUTPUT_COMMIT_LENGTH="${OUTPUT_COMMIT_LENGTH:-40}"
  OVERWRITE_OUTPUTS="${OVERWRITE_OUTPUTS:-false}"
  KEEP_FAILED_REPOS="${KEEP_FAILED_REPOS:-false}"
  VALIDATE_JSON="${VALIDATE_JSON:-true}"
  DRY_RUN="${DRY_RUN:-false}"
  CONFIG_FILE="${CONFIG_FILE:-/qwarium/home/ext.arlatyshev/trae-agent_analyse/trae_config.json}

  TRAE_AGENT_CMD="${TRAE_AGENT_CMD:-trae-cli run --file \"\$PROMPT_FILE\" --working-dir \"\$REPO_DIR\" --console-type simple --config-file \"\$CONFIG_FILE\" "}"
  AGENT_ENV_PASSTHROUGH="${AGENT_ENV_PASSTHROUGH:-OPENAI_API_KEY OPENAI_BASE_URL ANTHROPIC_API_KEY ANTHROPIC_BASE_URL GOOGLE_API_KEY GOOGLE_BASE_URL OPENROUTER_API_KEY OPENROUTER_BASE_URL DOUBAO_API_KEY DOUBAO_BASE_URL TRAE_CONFIG_FILE LANG LC_ALL}"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env-file)
        [[ $# -ge 2 ]] || die "--env-file requires a path"
        ENV_FILE="$2"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --limit)
        [[ $# -ge 2 ]] || die "--limit requires a number"
        PROMPTS_LIMIT="$2"
        shift 2
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command is missing: $1"
}

validate_config() {
  require_command git
  require_command "$PYTHON_BIN"
  if is_true "$VALIDATE_JSON"; then
    require_command "$JQ_BIN"
  fi

  "$PYTHON_BIN" - <<'PY' >/dev/null
try:
    import yaml
except ImportError as exc:
    raise SystemExit("PyYAML is required: python -m pip install PyYAML") from exc
PY

  [[ -d "$PROMPTS_DIR" ]] || die "PROMPTS_DIR does not exist: $PROMPTS_DIR"
  [[ "$PROMPTS_MAX_DEPTH" =~ ^[0-9]+$ ]] || die "PROMPTS_MAX_DEPTH must be a non-negative integer"
  [[ "$PROMPTS_LIMIT" =~ ^[0-9]+$ ]] || die "PROMPTS_LIMIT must be a non-negative integer"
  [[ "$OUTPUT_COMMIT_LENGTH" =~ ^[0-9]+$ ]] || die "OUTPUT_COMMIT_LENGTH must be a non-negative integer"

  mkdir -p -- "$WORK_ROOT" "$OUTPUT_DIR" "$OUTPUT_DIR/logs"
}

parse_yaml_prompt() {
  local yaml_file="$1"

  YAML_IDX=
  YAML_PROJECT=
  YAML_LANGUAGE=
  YAML_COMMIT=
  YAML_PROMPT=

  {
    IFS= read -r -d '' YAML_IDX
    IFS= read -r -d '' YAML_PROJECT
    IFS= read -r -d '' YAML_LANGUAGE
    IFS= read -r -d '' YAML_COMMIT
    IFS= read -r -d '' YAML_PROMPT
  } < <("$PYTHON_BIN" - "$yaml_file" <<'PY'
import sys
import yaml

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as fh:
    data = yaml.safe_load(fh) or {}

required = ["idx", "project", "language", "checked_commit", "prompt"]
missing = [key for key in required if data.get(key) is None]
if missing:
    raise SystemExit(f"Missing required YAML keys in {path}: {', '.join(missing)}")

for key in required:
    sys.stdout.write(str(data[key]))
    sys.stdout.write("\0")
PY
  )
}

sanitize_filename_part() {
  local value="$1"
  value="${value//\//__}"
  value="${value// /_}"
  printf '%s' "$value" | tr -c 'A-Za-z0-9._-' '_'
}

repo_url_for_project() {
  local project="$1"
  printf '%s/%s.git' "${GIT_BASE_URL%/}" "$project"
}

remove_git_metadata() {
  local repo_dir="$1"
  find "$repo_dir" -name .git -prune -exec rm -rf -- {} +
}

copy_logs_on_failure() {
  local task_name="$1"
  local stdout_file="$2"
  local stderr_file="$3"

  [[ -f "$stdout_file" ]] && cp -- "$stdout_file" "$OUTPUT_DIR/logs/${task_name}.stdout.log"
  [[ -f "$stderr_file" ]] && cp -- "$stderr_file" "$OUTPUT_DIR/logs/${task_name}.stderr.log"
}

collect_answer() {
  local task_name="$1"
  local task_answer_file="$2"
  local expected_repo_answer_file="$3"
  local agent_stdout_file="$4"
  local agent_stderr_file="$5"
  local final_answer_file="$6"
  local candidate=
  local tmp_answer="${final_answer_file}.tmp"

  if [[ -s "$task_answer_file" ]]; then
    candidate="$task_answer_file"
  elif [[ -s "$expected_repo_answer_file" ]]; then
    candidate="$expected_repo_answer_file"
  elif [[ -s "$agent_stdout_file" ]]; then
    candidate="$agent_stdout_file"
  fi

  if [[ -z "$candidate" ]]; then
    copy_logs_on_failure "$task_name" "$agent_stdout_file" "$agent_stderr_file"
    log "No answer found for $task_name"
    return 1
  fi

  cp -- "$candidate" "$tmp_answer"

  if is_true "$VALIDATE_JSON"; then
    if ! "$JQ_BIN" -e . "$tmp_answer" >/dev/null; then
      mv -- "$tmp_answer" "${final_answer_file}.invalid"
      copy_logs_on_failure "$task_name" "$agent_stdout_file" "$agent_stderr_file"
      log "Answer is not valid JSON: ${final_answer_file}.invalid"
      return 1
    fi
  fi

  mv -- "$tmp_answer" "$final_answer_file"
}

run_agent() {
  local repo_dir="$1"
  local prompt_file="$2"
  local answer_file="$3"
  local stdout_file="$4"
  local stderr_file="$5"
  local task_home="$6"
  local task_tmp="$7"
  local env_name
  local env_value
  local IFS=' ,'
  local -a agent_env

  agent_env=(
    "PATH=${PATH:-/usr/bin:/bin:/usr/sbin:/sbin}"
    "SHELL=${SHELL:-/bin/bash}"
    "REPO_DIR=$repo_dir"
    "PROMPT_FILE=$prompt_file"
    "ANSWER_FILE=$answer_file"
    "HOME=$task_home"
    "TMPDIR=$task_tmp"
    "XDG_CACHE_HOME=$task_home/.cache"
    "XDG_CONFIG_HOME=$task_home/.config"
    "XDG_DATA_HOME=$task_home/.local/share"
    "GIT_CONFIG_NOSYSTEM=1"
    "GIT_CONFIG_GLOBAL=/dev/null"
  )

  for env_name in $AGENT_ENV_PASSTHROUGH; do
    [[ -n "$env_name" ]] || continue
    [[ "$env_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "Invalid AGENT_ENV_PASSTHROUGH name: $env_name"
    if [[ "${!env_name+x}" == "x" ]]; then
      env_value="${!env_name}"
      agent_env+=("$env_name=$env_value")
    fi
  done

  mkdir -p -- "$task_home/.cache" "$task_home/.config" "$task_home/.local/share" "$task_tmp"

  (
    cd -- "$repo_dir"
    env -i "${agent_env[@]}" bash -lc "$TRAE_AGENT_CMD" >"$stdout_file" 2>"$stderr_file"
  )
}

process_prompt_inner() {
  local yaml_file="$1"
  local task_dir=
  CURRENT_TASK_DIR=

  cleanup() {
    local rc=$?
    if [[ -n "${CURRENT_TASK_DIR:-}" && -d "${CURRENT_TASK_DIR:-}" ]]; then
      if [[ "$rc" -eq 0 || "$rc" -eq 10 ]] || ! is_true "$KEEP_FAILED_REPOS"; then
        rm -rf -- "$CURRENT_TASK_DIR"
      else
        log "Keeping failed task dir for debugging: $CURRENT_TASK_DIR"
      fi
    fi
  }
  trap cleanup EXIT

  parse_yaml_prompt "$yaml_file"

  local safe_project safe_language commit_for_name task_name
  safe_project="$(sanitize_filename_part "$YAML_PROJECT")"
  safe_language="$(sanitize_filename_part "$YAML_LANGUAGE")"
  commit_for_name="${YAML_COMMIT:0:$OUTPUT_COMMIT_LENGTH}"
  task_name="${YAML_IDX}_${safe_project}_${safe_language}_${commit_for_name}"

  local final_answer_file="$OUTPUT_DIR/${task_name}.json"
  if [[ -e "$final_answer_file" ]] && ! is_true "$OVERWRITE_OUTPUTS"; then
    log "Skipping existing answer: $final_answer_file"
    return 10
  fi

  log "Prompt: $yaml_file"
  log "Project: $YAML_PROJECT @ $YAML_COMMIT"

  if is_true "$DRY_RUN"; then
    log "Dry run: would write $final_answer_file"
    return 0
  fi

  task_dir="$(mktemp -d "$WORK_ROOT/${task_name}.XXXXXX")"
  CURRENT_TASK_DIR="$task_dir"
  local repo_dir="$task_dir/repo"
  local prompt_file="$task_dir/prompt.txt"
  local task_answer_file="$task_dir/answer.json"
  local stdout_file="$task_dir/agent.stdout"
  local stderr_file="$task_dir/agent.stderr"
  local task_home="$task_dir/home"
  local task_tmp="$task_dir/tmp"
  local repo_url

  repo_url="$(repo_url_for_project "$YAML_PROJECT")"
  printf '%s\n' "$YAML_PROMPT" >"$prompt_file"

  log "Cloning $repo_url"
  git clone --quiet --no-checkout -- "$repo_url" "$repo_dir"
  git -C "$repo_dir" fetch --quiet origin "$YAML_COMMIT" || true
  git -C "$repo_dir" -c advice.detachedHead=false checkout --quiet --detach "$YAML_COMMIT"

  remove_git_metadata "$repo_dir"
  [[ ! -e "$repo_dir/.git" ]] || die "Failed to remove .git from $repo_dir"

  log "Running Trae Agent in isolated checkout"
  if ! run_agent "$repo_dir" "$prompt_file" "$task_answer_file" "$stdout_file" "$stderr_file" "$task_home" "$task_tmp"; then
    copy_logs_on_failure "$task_name" "$stdout_file" "$stderr_file"
    log "Trae Agent failed for $task_name; logs saved to $OUTPUT_DIR/logs"
    return 1
  fi

  collect_answer \
    "$task_name" \
    "$task_answer_file" \
    "$repo_dir/answer_${YAML_COMMIT}.json" \
    "$stdout_file" \
    "$stderr_file" \
    "$final_answer_file"

  log "Saved answer: $final_answer_file"
}

process_prompt() {
  (
    set -Eeuo pipefail
    process_prompt_inner "$1"
  )
}

list_prompt_files() {
  find "$PROMPTS_DIR" -maxdepth "$PROMPTS_MAX_DEPTH" -type f -name "$PROMPTS_PATTERN" | sort
}

main() {
  parse_args "$@"
  load_env
  apply_defaults
  parse_args "$@"
  validate_config

  log "Using env: $ENV_FILE"
  log "Prompts: $PROMPTS_DIR/$PROMPTS_PATTERN"
  log "Output: $OUTPUT_DIR"

  local processed=0 succeeded=0 skipped=0 failed=0
  local yaml_file rc

  while IFS= read -r yaml_file; do
    [[ -n "$yaml_file" ]] || continue
    if [[ "$PROMPTS_LIMIT" -gt 0 && "$processed" -ge "$PROMPTS_LIMIT" ]]; then
      break
    fi

    processed=$((processed + 1))

    set +e
    process_prompt "$yaml_file"
    rc=$?
    set -e

    case "$rc" in
      0)
        succeeded=$((succeeded + 1))
        ;;
      10)
        skipped=$((skipped + 1))
        ;;
      *)
        failed=$((failed + 1))
        if is_true "${STOP_ON_ERROR:-false}"; then
          break
        fi
        ;;
    esac
  done < <(list_prompt_files)

  log "Done: processed=$processed succeeded=$succeeded skipped=$skipped failed=$failed"
  [[ "$failed" -eq 0 ]]
}

main "$@"
