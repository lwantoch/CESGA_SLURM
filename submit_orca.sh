#!/usr/bin/env bash
# =============================================================================
# submit_orca.sh  (Slurm Option B: job arrays)
#
# English explanation (what this script does):
#   - Submitter/orchestrator to run on the LOGIN node.
#   - Submits:
#       (1) a SINGLE ORCA input file (.inp) as one Slurm job
#       (2) MANY .inp files found recursively as a Slurm ARRAY job
#   - Pre-filters work to avoid wasting queue slots:
#       * default: submit only if output is missing or failed
#       * --only-missing: submit only if output is missing
#       * --only-failed : submit only if output exists but is not successful
#       * -o           : overwrite policy (submit everything)
#   - Forwards optional overrides to the worker script (run_orca.sh):
#       -nproc N, --method, --basis, -d DISP, --restart, etc.
#     The worker applies those overrides by patching a temporary copy of the
#     input file for that run.
#
# Requirements:
#   - A worker script named run_orca.sh in the same directory as this file.
#   - run_orca.sh must be executable.
#
# Assumptions about ORCA output naming:
#   - For input: /path/to/name.inp
#     expected out: /path/to/name.out
#   - Success = out contains "ORCA TERMINATED NORMALLY"
#
# If your naming differs, change derive_out_path().
# =============================================================================

set -euo pipefail

# -----------------------------
# Defaults: discovery / array
# -----------------------------
RECURSIVE=0
PATTERN="*muster.inp"
ROOT="."
MAXPAR=50  # array throttle: --array=1-N%MAXPAR

# -----------------------------
# Defaults: policy / filtering
# -----------------------------
OVERWRITE=0     # -o
RESTART=0       # --restart (forwarded to worker)
ONLY_MISSING=0  # --only-missing
ONLY_FAILED=0   # --only-failed

# -----------------------------
# Overrides forwarded to worker
# -----------------------------
NPROC=""    # -nproc N
METHOD=""   # --method B3LYP
BASIS=""    # --basis def2-SVP
DISP=""     # -d D3BJ / D4 / none

# -----------------------------
# Slurm resource defaults
# -----------------------------
SLURM_PARTITION="compute"
SLURM_TIME="24:00:00"
SLURM_MEM="32G"
SLURM_CPUS=16

JOBNAME_SINGLE="orca1"
JOBNAME_ARRAY="orcaA"

# -----------------------------
# Paths
# -----------------------------
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER="${script_dir}/run_orca.sh"

# -----------------------------
# Success marker (keep consistent with run_orca.sh)
# -----------------------------
ORCA_SUCCESS_MARKER="ORCA TERMINATED NORMALLY"

# -----------------------------
# Help / usage
# -----------------------------
usage() {
  cat <<'EOF'
submit_orca.sh — submit ORCA jobs to Slurm (single job or job array)

SINGLE MODE:
  ./submit_orca.sh path/to/job.inp [options]

ARRAY MODE (recursive):
  ./submit_orca.sh -r [-p PATTERN] [ROOT] [options]

Discovery:
  -r                  Enable recursive search (array mode)
  -p PATTERN          find -name PATTERN (default: "*muster.inp")
  ROOT                Root directory (default: .)

Policy / filtering:
  -o                  Overwrite policy: submit even if successful output exists
  --only-missing      Submit only if expected *.out is missing
  --only-failed       Submit only if *.out exists but NOT successful
  --restart           Ask worker to restart from .gbw if possible

Overrides forwarded to worker (UPSERT into input copy for this run only):
  -nproc N            Set %pal nprocs N end (upsert)
  --method M          Set/replace method/functional on first "! ..." line (heuristic)
  --basis B           Set/replace basis set on first "! ..." line (heuristic)
  -d DISP             Set/replace dispersion token on first "! ..." line (heuristic),
                      use "-d none" to remove dispersion token

Array control:
  -P MAXPAR           Max parallel array tasks (default: 50)

Slurm resources (optional):
  --partition NAME    default: compute
  --time HH:MM:SS     default: 24:00:00
  --mem 32G           default: 32G
  --cpus N            default: 16

Examples:
  # Single input
  ./submit_orca.sh calc/job.inp --method B3LYP --basis def2-SVP -d D3BJ

  # Recursive array: rerun only failed jobs, attempt restart
  ./submit_orca.sh -r -p "*muster.inp" data/ --only-failed --restart -P 80
EOF
}

# -----------------------------
# Robust absolute path helper
# -----------------------------
abspath() {
  python3 - "$1" <<'PY'
import os, sys
print(os.path.abspath(sys.argv[1]))
PY
}

# -----------------------------
# Output naming convention:
# input: /x/y/name.inp -> out: /x/y/name.out
# -----------------------------
derive_out_path() {
  local inp="$1"
  local dir base
  dir="$(dirname "$inp")"
  base="$(basename "$inp" .inp)"
  echo "${dir}/${base}.out"
}

# -----------------------------
# Success detection
# -----------------------------
out_is_success() {
  local out="$1"
  [[ -f "$out" ]] && grep -q "$ORCA_SUCCESS_MARKER" "$out"
}

# -----------------------------
# Decide whether this input should be submitted
# -----------------------------
should_include() {
  local inp="$1"
  local out
  out="$(derive_out_path "$inp")"

  if [[ "$OVERWRITE" -eq 1 ]]; then
    return 0
  fi

  if [[ "$ONLY_MISSING" -eq 1 ]]; then
    [[ ! -f "$out" ]]
    return $?
  fi

  if [[ "$ONLY_FAILED" -eq 1 ]]; then
    [[ -f "$out" ]] || return 1
    out_is_success "$out" && return 1
    return 0
  fi

  # Default: include if not successful
  out_is_success "$out" && return 1
  return 0
}

# -----------------------------
# Preconditions
# -----------------------------
require_worker() {
  if [[ ! -f "$WORKER" ]]; then
    echo "ERROR: Worker script not found: $WORKER" >&2
    echo "Expected: run_orca.sh next to submit_orca.sh" >&2
    exit 2
  fi
  if [[ ! -x "$WORKER" ]]; then
    echo "ERROR: Worker script is not executable: $WORKER" >&2
    echo "Fix: chmod +x run_orca.sh" >&2
    exit 2
  fi
}

# -----------------------------
# Parse CLI arguments
# -----------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -r) RECURSIVE=1; shift ;;
      -p) PATTERN="${2:?ERROR: -p needs a pattern}"; shift 2 ;;
      -P) MAXPAR="${2:?ERROR: -P needs an int}"; shift 2 ;;

      -o) OVERWRITE=1; shift ;;
      --restart) RESTART=1; shift ;;
      --only-missing) ONLY_MISSING=1; shift ;;
      --only-failed) ONLY_FAILED=1; shift ;;

      -nproc) NPROC="${2:?ERROR: -nproc needs an int}"; shift 2 ;;
      --method) METHOD="${2:?ERROR: --method needs a value}"; shift 2 ;;
      --basis) BASIS="${2:?ERROR: --basis needs a value}"; shift 2 ;;
      -d) DISP="${2:?ERROR: -d needs a value}"; shift 2 ;;

      --partition) SLURM_PARTITION="${2:?ERROR: --partition needs a value}"; shift 2 ;;
      --time) SLURM_TIME="${2:?ERROR: --time needs a value}"; shift 2 ;;
      --mem) SLURM_MEM="${2:?ERROR: --mem needs a value}"; shift 2 ;;
      --cpus) SLURM_CPUS="${2:?ERROR: --cpus needs an int}"; shift 2 ;;

      -h|--help) usage; exit 0 ;;
      --) shift; break ;;
      -*)
        echo "ERROR: unknown option: $1" >&2
        usage
        exit 2
        ;;
      *)
        # positional:
        # - single mode: input.inp
        # - array mode: ROOT dir
        ROOT="$1"
        shift
        ;;
    esac
  done
}

# -----------------------------
# Validate arguments
# -----------------------------
validate_args() {
  if [[ "$ONLY_MISSING" -eq 1 && "$ONLY_FAILED" -eq 1 ]]; then
    echo "ERROR: --only-missing and --only-failed are mutually exclusive" >&2
    exit 2
  fi

  if [[ -n "$NPROC" && ! "$NPROC" =~ ^[0-9]+$ ]]; then
    echo "ERROR: -nproc must be integer, got: $NPROC" >&2
    exit 2
  fi
  if [[ ! "$SLURM_CPUS" =~ ^[0-9]+$ ]]; then
    echo "ERROR: --cpus must be integer, got: $SLURM_CPUS" >&2
    exit 2
  fi
  if [[ ! "$MAXPAR" =~ ^[0-9]+$ ]]; then
    echo "ERROR: -P must be integer, got: $MAXPAR" >&2
    exit 2
  fi

  require_worker
  mkdir -p "${script_dir}/logs"
}

# -----------------------------
# Build sbatch --export list
# -----------------------------
build_exports_base() {
  local exports="ALL"
  exports+=",ORCA_WORKER=${WORKER}"

  exports+=",ORCA_OVERWRITE=${OVERWRITE}"
  exports+=",ORCA_RESTART=${RESTART}"
  exports+=",ORCA_ONLY_MISSING=${ONLY_MISSING}"
  exports+=",ORCA_ONLY_FAILED=${ONLY_FAILED}"

  exports+=",ORCA_NPROC=${NPROC}"
  exports+=",ORCA_METHOD=${METHOD}"
  exports+=",ORCA_BASIS=${BASIS}"
  exports+=",ORCA_DISP=${DISP}"

  echo "$exports"
}

# -----------------------------
# Submit SINGLE job
# -----------------------------
submit_single() {
  local input="$1"
  local abs
  abs="$(abspath "$input")"

  if [[ ! -f "$abs" ]]; then
    echo "ERROR: input file not found: $abs" >&2
    exit 2
  fi

  if ! should_include "$abs"; then
    echo "Skip by policy (nothing to do): $abs"
    exit 0
  fi

  local exports
  exports="$(build_exports_base)"
  exports+=",ORCA_INPUT=${abs}"

  sbatch --export="$exports" <<SBATCH_EOF
#!/usr/bin/env bash
#SBATCH --job-name=${JOBNAME_SINGLE}
#SBATCH --partition=${SLURM_PARTITION}
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=${SLURM_CPUS}
#SBATCH --mem=${SLURM_MEM}
#SBATCH --time=${SLURM_TIME}
#SBATCH --output=${script_dir}/logs/%x_%j.out
#SBATCH --error=${script_dir}/logs/%x_%j.err
#SBATCH --requeue

set -euo pipefail
mkdir -p "${script_dir}/logs"

# Build worker flags from ORCA_* env vars
RUN_FLAGS=()
[[ "\${ORCA_OVERWRITE:-0}" -eq 1 ]] && RUN_FLAGS+=("-o")
[[ "\${ORCA_RESTART:-0}" -eq 1 ]] && RUN_FLAGS+=("--restart")
[[ "\${ORCA_ONLY_MISSING:-0}" -eq 1 ]] && RUN_FLAGS+=("--only-missing")
[[ "\${ORCA_ONLY_FAILED:-0}" -eq 1 ]] && RUN_FLAGS+=("--only-failed")

# Default NPROC: use allocated cores if user did not set -nproc explicitly
if [[ -n "\${ORCA_NPROC:-}" ]]; then
  RUN_FLAGS+=("-nproc" "\${ORCA_NPROC}")
else
  RUN_FLAGS+=("-nproc" "\${SLURM_CPUS_PER_TASK}")
fi

[[ -n "\${ORCA_METHOD:-}" ]] && RUN_FLAGS+=("--method" "\${ORCA_METHOD}")
[[ -n "\${ORCA_BASIS:-}"  ]] && RUN_FLAGS+=("--basis"  "\${ORCA_BASIS}")
[[ -n "\${ORCA_DISP:-}"   ]] && RUN_FLAGS+=("-d"       "\${ORCA_DISP}")

"\${ORCA_WORKER}" "\${RUN_FLAGS[@]}" "\${ORCA_INPUT}"
SBATCH_EOF
}

# -----------------------------
# Submit ARRAY job (recursive)
# -----------------------------
submit_array() {
  if [[ ! -d "$ROOT" ]]; then
    echo "ERROR: ROOT is not a directory: $ROOT" >&2
    exit 2
  fi

  local list
  list="${script_dir}/orca_inputs_${USER}_$(date +%Y%m%d_%H%M%S).txt"
  : > "$list"

  # Find candidates, sort deterministically, then filter.
  while IFS= read -r -d '' f; do
    local abs
    abs="$(abspath "$f")"
    if should_include "$abs"; then
      echo "$abs" >> "$list"
    fi
  done < <(find "$ROOT" -type f -name "$PATTERN" -print0 | sort -z)

  local n
  n="$(wc -l < "$list" | tr -d ' ')"
  if [[ "$n" -eq 0 ]]; then
    echo "Nothing to submit (after filtering). List created: $list"
    exit 0
  fi

  echo "Submitting ARRAY job:"
  echo "  tasks        : $n"
  echo "  max parallel : $MAXPAR"
  echo "  list         : $list"

  local exports
  exports="$(build_exports_base)"
  exports+=",ORCA_LIST=${list}"

  sbatch --array=1-"$n"%${MAXPAR} --export="$exports" <<SBATCH_EOF
#!/usr/bin/env bash
#SBATCH --job-name=${JOBNAME_ARRAY}
#SBATCH --partition=${SLURM_PARTITION}
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=${SLURM_CPUS}
#SBATCH --mem=${SLURM_MEM}
#SBATCH --time=${SLURM_TIME}
#SBATCH --output=${script_dir}/logs/%x_%A_%a.out
#SBATCH --error=${script_dir}/logs/%x_%A_%a.err
#SBATCH --requeue

set -euo pipefail
mkdir -p "${script_dir}/logs"

# One line per task, indexed by SLURM_ARRAY_TASK_ID (1-based).
INPUT="\$(sed -n "\${SLURM_ARRAY_TASK_ID}p" "\${ORCA_LIST}")"
[[ -n "\$INPUT" ]] || { echo "ERROR: empty input for array id \$SLURM_ARRAY_TASK_ID" >&2; exit 2; }

RUN_FLAGS=()
[[ "\${ORCA_OVERWRITE:-0}" -eq 1 ]] && RUN_FLAGS+=("-o")
[[ "\${ORCA_RESTART:-0}" -eq 1 ]] && RUN_FLAGS+=("--restart")
[[ "\${ORCA_ONLY_MISSING:-0}" -eq 1 ]] && RUN_FLAGS+=("--only-missing")
[[ "\${ORCA_ONLY_FAILED:-0}" -eq 1 ]] && RUN_FLAGS+=("--only-failed")

if [[ -n "\${ORCA_NPROC:-}" ]]; then
  RUN_FLAGS+=("-nproc" "\${ORCA_NPROC}")
else
  RUN_FLAGS+=("-nproc" "\${SLURM_CPUS_PER_TASK}")
fi

[[ -n "\${ORCA_METHOD:-}" ]] && RUN_FLAGS+=("--method" "\${ORCA_METHOD}")
[[ -n "\${ORCA_BASIS:-}"  ]] && RUN_FLAGS+=("--basis"  "\${ORCA_BASIS}")
[[ -n "\${ORCA_DISP:-}"   ]] && RUN_FLAGS+=("-d"       "\${ORCA_DISP}")

"\${ORCA_WORKER}" "\${RUN_FLAGS[@]}" "\$INPUT"
SBATCH_EOF
}

# -----------------------------
# MAIN
# -----------------------------
parse_args "$@"
validate_args

# Mode selection:
# - If -r is set => array mode
# - else => single mode; ROOT must be an input file, not "."
if [[ "$RECURSIVE" -eq 1 ]]; then
  submit_array
else
  if [[ "$ROOT" == "." ]]; then
    echo "ERROR: no input file provided for single mode. Use -r for recursive mode." >&2
    usage
    exit 2
  fi
  submit_single "$ROOT"
fi
