#!/usr/bin/env bash
# ==============================================================================
# run_orca.sh — Robust ORCA runner for HPC / SLURM with input patching
# ==============================================================================
#
# PURPOSE
#   Run a single ORCA input file (.inp) in a reproducible, automation-friendly way.
#   This script supports:
#     - Skipping already-successful calculations by default (idempotent behavior)
#     - Overwrite mode to force re-running even if output exists
#     - "Only missing" / "only failed" filters
#     - A conservative restart mode (read existing wavefunction from .gbw)
#     - Patching the ORCA input to set:
#         * number of cores (via %pal nprocs N end)
#         * method/functional, basis set, dispersion (via the leading "! ..." line)
#
# KEY IDEAS (HOW IT WORKS)
#   1) Determine output name as <base>.out in the same directory as the input.
#   2) Decide whether to run based on:
#        - output exists?
#        - output contains "ORCA TERMINATED NORMALLY" (heuristic success marker)
#        - user flags: --only-missing / --only-failed / -o
#   3) Create a patched input copy (<base>.patched.inp) that includes requested
#      changes (nprocs, method/basis/disp, restart keywords).
#   4) Run ORCA in the input directory so all output files are created next to
#      the input (typical ORCA workflow).
#   5) Use scratch directory (TMPDIR / ORCA_TMPDIR) to keep heavy temporary I/O
#      off network filesystems.
#
# RESTART (CONSERVATIVE)
#   - If --restart is set and <base>.gbw exists:
#       * Append "MOREAD" to the first "! ..." line (if missing)
#       * Add %moinp "<base>.gbw" if not already present
#   - This aims to restart SCF / wavefunction guess. Geometry continuation
#     (optimizations) can require additional, job-type-specific handling.
#
# EXIT CODES
#   0  success (or skipped successfully)
#   2  user input / option error
#   3  environment error (orca not found)
#   4  ORCA did not terminate normally (heuristic)
#
# REQUIREMENTS
#   - ORCA accessible via "module load orca" (adapt if your cluster uses a different module name)
#   - python3 available (used for robust input patching)
#
# EXAMPLES
#   Run once (skip if already successful):
#     ./run_orca.sh path/to/job.inp
#
#   Force rerun:
#     ./run_orca.sh -o path/to/job.inp
#
#   Only run missing outputs:
#     ./run_orca.sh --only-missing path/to/job.inp
#
#   Only rerun failed outputs, attempt restart if .gbw exists:
#     ./run_orca.sh --only-failed --restart path/to/job.inp
#
#   Patch nprocs + method/basis + dispersion:
#     ./run_orca.sh -nproc 16 --method B3LYP --basis def2-SVP -d D3BJ job.inp
#
#   Remove dispersion explicitly:
#     ./run_orca.sh --method PBE0 --basis def2-TZVP -d none job.inp
#
# NOTES / LIMITATIONS
#   - The method/basis patch is a pragmatic heuristic:
#       it assumes the first two tokens after "!" correspond to method and basis.
#     If your inputs use a different ordering, tell me and I’ll adapt the parser.
#   - Success detection uses "ORCA TERMINATED NORMALLY". If your ORCA version
#     prints a different marker, change ORCA_SUCCESS_MARKER below.
#
# ==============================================================================

set -euo pipefail

# -----------------------------
# User-facing options (defaults)
# -----------------------------
FORCE_OVERWRITE_OUTPUTS=0
REQUESTED_NPROCS=""                # empty means "do not patch"
REQUEST_RESTART=0
RUN_ONLY_IF_OUTPUT_MISSING=0
RUN_ONLY_IF_OUTPUT_FAILED=0

REQUESTED_METHOD_OR_FUNCTIONAL=""  # e.g. B3LYP, PBE0, M06-2X
REQUESTED_BASIS_SET=""             # e.g. def2-SVP, def2-TZVP
REQUESTED_DISPERSION=""            # e.g. D3BJ, D4, none

# -----------------------------
# Constants / heuristics
# -----------------------------
ORCA_SUCCESS_MARKER="ORCA TERMINATED NORMALLY"

# -----------------------------
# Parse CLI arguments
# -----------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      FORCE_OVERWRITE_OUTPUTS=1
      shift
      ;;
    -nproc)
      REQUESTED_NPROCS="${2:?ERROR: -nproc requires an integer}"
      shift 2
      ;;
    --restart)
      REQUEST_RESTART=1
      shift
      ;;
    --only-missing)
      RUN_ONLY_IF_OUTPUT_MISSING=1
      shift
      ;;
    --only-failed)
      RUN_ONLY_IF_OUTPUT_FAILED=1
      shift
      ;;
    --method)
      REQUESTED_METHOD_OR_FUNCTIONAL="${2:?ERROR: --method requires a value}"
      shift 2
      ;;
    --basis)
      REQUESTED_BASIS_SET="${2:?ERROR: --basis requires a value}"
      shift 2
      ;;
    -d)
      REQUESTED_DISPERSION="${2:?ERROR: -d requires a value (e.g. D3BJ, D4, none)}"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -*) # unknown option
      echo "ERROR: unknown option: $1" >&2
      exit 2
      ;;
    *)  # first non-option is input file
      break
      ;;
  esac
done

ORCA_INPUT_FILE="${1:?ERROR: missing ORCA input file (.inp)}"
if [[ ! -f "$ORCA_INPUT_FILE" ]]; then
  echo "ERROR: input does not exist: $ORCA_INPUT_FILE" >&2
  exit 2
fi

# -----------------------------
# Validate mutually exclusive filters
# -----------------------------
if [[ "$RUN_ONLY_IF_OUTPUT_MISSING" -eq 1 && "$RUN_ONLY_IF_OUTPUT_FAILED" -eq 1 ]]; then
  echo "ERROR: --only-missing and --only-failed are mutually exclusive" >&2
  exit 2
fi

# -----------------------------
# Derive paths (workdir, base, outputs)
# -----------------------------
WORKING_DIRECTORY="$(cd "$(dirname "$ORCA_INPUT_FILE")" && pwd)"
INPUT_FILENAME="$(basename "$ORCA_INPUT_FILE")"
JOB_BASENAME="${INPUT_FILENAME%.*}"  # remove extension
ORCA_OUTPUT_FILE="${WORKING_DIRECTORY}/${JOB_BASENAME}.out"
ORCA_GBW_FILE="${WORKING_DIRECTORY}/${JOB_BASENAME}.gbw"

cd "$WORKING_DIRECTORY"

# -----------------------------
# Helper: detect success from output
# -----------------------------
orca_output_is_successful() {
  [[ -f "$ORCA_OUTPUT_FILE" ]] && grep -q "$ORCA_SUCCESS_MARKER" "$ORCA_OUTPUT_FILE"
}

# -----------------------------
# Decide whether we should run (idempotent behavior)
# -----------------------------
if [[ "$FORCE_OVERWRITE_OUTPUTS" -eq 0 ]]; then
  if [[ "$RUN_ONLY_IF_OUTPUT_MISSING" -eq 1 ]]; then
    if [[ -f "$ORCA_OUTPUT_FILE" ]]; then
      echo "SKIP (--only-missing): output exists: $ORCA_OUTPUT_FILE"
      exit 0
    fi
  elif [[ "$RUN_ONLY_IF_OUTPUT_FAILED" -eq 1 ]]; then
    if [[ ! -f "$ORCA_OUTPUT_FILE" ]]; then
      echo "SKIP (--only-failed): output missing: $ORCA_OUTPUT_FILE"
      exit 0
    fi
    if orca_output_is_successful; then
      echo "SKIP (--only-failed): already successful: $ORCA_OUTPUT_FILE"
      exit 0
    fi
    # else: output exists and not successful => run
  else
    # default mode: skip if already successful
    if orca_output_is_successful; then
      echo "SKIP: already successful: $ORCA_OUTPUT_FILE"
      exit 0
    fi
    # else: missing or failed => run
  fi
fi

# -----------------------------
# Load environment / ensure ORCA exists
# -----------------------------
module purge
module load orca

if ! command -v orca &>/dev/null; then
  echo "ERROR: 'orca' not found in PATH after module load" >&2
  exit 3
fi

# -----------------------------
# Validate requested nprocs
# -----------------------------
if [[ -n "$REQUESTED_NPROCS" ]]; then
  [[ "$REQUESTED_NPROCS" =~ ^[0-9]+$ ]] || { echo "ERROR: -nproc must be an integer" >&2; exit 2; }

  # Optional SLURM consistency check: do not oversubscribe
  if [[ -n "${SLURM_CPUS_PER_TASK:-}" && "$REQUESTED_NPROCS" -gt "$SLURM_CPUS_PER_TASK" ]]; then
    echo "ERROR: -nproc=$REQUESTED_NPROCS > SLURM_CPUS_PER_TASK=$SLURM_CPUS_PER_TASK" >&2
    exit 2
  fi
fi

# -----------------------------
# Setup scratch (local temp I/O)
# -----------------------------
SCRATCH_DIRECTORY="/scratch/${USER}/orca_${SLURM_JOB_ID:-local}_$$"
mkdir -p "$SCRATCH_DIRECTORY"
export TMPDIR="$SCRATCH_DIRECTORY"
export ORCA_TMPDIR="$SCRATCH_DIRECTORY"  # harmless even if your build ignores it

cleanup_scratch() { rm -rf "$SCRATCH_DIRECTORY"; }
trap cleanup_scratch EXIT

# -----------------------------
# Patch ORCA input into a temporary file
#   - We always write a patched file for simplicity and traceability.
# -----------------------------
PATCHED_INPUT_FILE="${WORKING_DIRECTORY}/${JOB_BASENAME}.patched.inp"

python3 - \
  "$ORCA_INPUT_FILE" \
  "$PATCHED_INPUT_FILE" \
  "$REQUESTED_NPROCS" \
  "$REQUESTED_METHOD_OR_FUNCTIONAL" \
  "$REQUESTED_BASIS_SET" \
  "$REQUESTED_DISPERSION" \
  "$REQUEST_RESTART" \
  "$ORCA_GBW_FILE" <<'PY'
import os
import re
import sys

input_path, output_path = sys.argv[1], sys.argv[2]
requested_nprocs = sys.argv[3].strip()
requested_method = sys.argv[4].strip()
requested_basis  = sys.argv[5].strip()
requested_disp   = sys.argv[6].strip()
request_restart  = int(sys.argv[7])
gbw_path         = sys.argv[8]

lines = open(input_path, "r", encoding="utf-8", errors="replace").read().splitlines(True)

def find_first_bang_line_index(ls):
  for idx, ln in enumerate(ls):
    if ln.strip() and ln.lstrip().startswith("!"):
      return idx
  return None

def patch_bang_line(line: str, method: str, basis: str, disp: str) -> str:
  """
  Pragmatic patch of the first '! ...' line:
    - assumes tokens after '!' are in the common order: METHOD BASIS [other keywords...]
    - removes existing known dispersion tokens before inserting the requested one
  """
  toks = line.strip().split()
  if not toks or toks[0] != "!":
    return line

  body = toks[1:]

  # Remove known dispersion keywords (best-effort, conservative)
  known_disp_tokens = {"D3", "D3BJ", "D3ZERO", "D4", "VV10", "NL"}
  body = [t for t in body if t.upper() not in known_disp_tokens]

  # Replace method/basis if requested (heuristic: first two tokens)
  if method:
    if body:
      body[0] = method
    else:
      body = [method]

  if basis:
    if len(body) >= 2:
      body[1] = basis
    elif len(body) == 1:
      body.append(basis)
    else:
      # unlikely: no tokens at all; choose a safe placeholder
      body = ["HF", basis]

  # Insert dispersion if requested (unless 'none')
  if disp and disp.lower() != "none":
    # Place dispersion after method/basis if present, else append
    insert_pos = 2 if len(body) >= 2 else len(body)
    body.insert(insert_pos, disp)

  return "! " + " ".join(body) + "\n"

def ensure_moread_and_moinp(ls, gbw_file):
  """
  Conservative restart:
    - Add MOREAD to the first bang line (if missing)
    - Add %moinp "<gbw>" if missing and gbw exists
  """
  if not os.path.isfile(gbw_file):
    return ls  # nothing to do

  bang_idx = find_first_bang_line_index(ls)
  if bang_idx is not None:
    if "MOREAD" not in ls[bang_idx].upper():
      ls[bang_idx] = ls[bang_idx].rstrip("\n") + " MOREAD\n"

  # Add %moinp if missing
  has_moinp = any(ln.strip().lower().startswith("%moinp") for ln in ls)
  if not has_moinp:
    # Put it near top; after %pal if there is one
    insert_at = 0
    for i, ln in enumerate(ls):
      if ln.lstrip().lower().startswith("%pal"):
        # place after end of %pal block
        j = i + 1
        while j < len(ls) and ls[j].strip().lower() != "end":
          j += 1
        insert_at = min(j + 1, len(ls))
        break
    ls[insert_at:insert_at] = [f'%moinp "{os.path.basename(gbw_file)}"\n']

  return ls

def patch_or_insert_pal_nprocs(ls, nprocs: str):
  """
  Ensure a %pal block with 'nprocs N' exists.
  - If %pal ... end exists: replace or insert the nprocs line inside it.
  - Else: insert a new %pal block near the top (after comments/blanks, and after '! ...' if it appears early).
  """
  if not nprocs:
    return ls

  if not re.fullmatch(r"\d+", nprocs):
    raise SystemExit("ERROR: -nproc must be an integer")

  # Locate %pal block (if any)
  pal_start = None
  pal_end = None
  for i, ln in enumerate(ls):
    if ln.lstrip().lower().startswith("%pal"):
      pal_start = i
      j = i + 1
      while j < len(ls):
        if ls[j].strip().lower() == "end":
          pal_end = j
          break
        j += 1
      break

  if pal_start is not None and pal_end is not None:
    # Replace or insert nprocs line in the block
    for k in range(pal_start + 1, pal_end):
      if ls[k].strip().lower().startswith("nprocs"):
        ls[k] = f"  nprocs {nprocs}\n"
        return ls
    # Not found => insert right after %pal
    ls.insert(pal_start + 1, f"  nprocs {nprocs}\n")
    return ls

  # Insert new block near the top
  insert_at = 0
  while insert_at < len(ls) and (ls[insert_at].strip() == "" or ls[insert_at].lstrip().startswith("#")):
    insert_at += 1

  # If an early bang line exists, insert after it
  if insert_at < len(ls) and ls[insert_at].lstrip().startswith("!"):
    insert_at += 1

  block = ["%pal\n", f"  nprocs {nprocs}\n", "end\n"]
  ls[insert_at:insert_at] = block
  return ls

# --- Apply patches ---

# 1) Patch the first '! ...' line if requested
bang_idx = find_first_bang_line_index(lines)
if bang_idx is not None and (requested_method or requested_basis or requested_disp):
  lines[bang_idx] = patch_bang_line(lines[bang_idx], requested_method, requested_basis, requested_disp)

# 2) Ensure %pal nprocs if requested
lines = patch_or_insert_pal_nprocs(lines, requested_nprocs)

# 3) Restart handling (conservative) if requested
if request_restart:
  lines = ensure_moread_and_moinp(lines, gbw_path)

open(output_path, "w", encoding="utf-8").write("".join(lines))
PY

# -----------------------------
# Run ORCA
#   - Run in WORKING_DIRECTORY to keep ORCA outputs next to inputs
#   - Redirect stdout to <base>.out (common convention)
# -----------------------------
echo "=== ORCA RUN START ==="
echo "Host:     $(hostname)"
echo "Workdir:  $WORKING_DIRECTORY"
echo "Input:    $ORCA_INPUT_FILE"
echo "Patched:  $PATCHED_INPUT_FILE"
echo "Output:   $ORCA_OUTPUT_FILE"
echo "Scratch:  $SCRATCH_DIRECTORY"
echo "SLURM:    JobID=${SLURM_JOB_ID:-N/A} CPUs=${SLURM_CPUS_PER_TASK:-N/A} Mem=${SLURM_MEM_PER_NODE:-N/A}"
echo "======================"

orca "$PATCHED_INPUT_FILE" > "$ORCA_OUTPUT_FILE"

# -----------------------------
# Validate completion (heuristic)
# -----------------------------
if ! grep -q "$ORCA_SUCCESS_MARKER" "$ORCA_OUTPUT_FILE"; then
  echo "ERROR: ORCA did not terminate normally (marker missing: '$ORCA_SUCCESS_MARKER')" >&2
  echo "Output: $ORCA_OUTPUT_FILE" >&2
  exit 4
fi

echo "OK: ORCA terminated normally: $ORCA_OUTPUT_FILE"
