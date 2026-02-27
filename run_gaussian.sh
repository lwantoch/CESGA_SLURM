#!/usr/bin/env bash
# ==============================================================================
# run_gaussian.sh — robust wrapper to run a single Gaussian16 job (.com input)
#
# What this script does (high level):
#   1) Parses CLI options controlling overwrite/skip policy and optional overrides.
#   2) Determines WORKDIR/BASE/LOG from the provided input .com file.
#   3) Applies a “skip policy” to avoid re-running successful jobs unless requested.
#   4) Loads Gaussian16 via environment modules (HPC-friendly).
#   5) Creates a per-job scratch directory (GAUSS_SCRDIR) and cleans it on exit.
#   6) Optionally generates a restart input that reads geometry + guess from .chk.
#   7) Optionally patches the input route section:
#        - upsert %NProcShared
#        - replace/add METHOD/BASIS (the first “X/Y” token)
#        - upsert/remove EmpiricalDispersion
#   8) Runs g16 and verifies “Normal termination”.
#
# Typical usage:
#   ./run_gaussian.sh myjob.com
#   ./run_gaussian.sh --only-missing myjob.com
#   ./run_gaussian.sh --only-failed myjob.com
#   ./run_gaussian.sh --restart myjob.com
#   ./run_gaussian.sh -nproc 16 --method B3LYP --basis def2SVP -d GD3BJ myjob.com
#   ./run_gaussian.sh -o myjob.com                 # force re-run even if successful
#
# Exit codes (informal):
#   0  success / or skipped cleanly
#   2  CLI/usage error (missing file, unknown option, mutually exclusive flags)
#   4  Gaussian run ended without “Normal termination”
#
# Assumptions / notes:
#   - Gaussian input is a standard .com with Link0 lines (%...), then a route line (#...).
#   - Restart expects BASE.chk (unless your original input uses different %Chk; see notes).
#   - Patching assumes the first METHOD/BASIS appears as "X/Y" somewhere in the route section.
#   - Uses environment modules: `module load gaussian/g16` and expects `g16` in PATH.
# ==============================================================================

set -euo pipefail
# -e: exit on error
# -u: error on unset variables
# -o pipefail: propagate errors in pipelines

# -------- options (defaults) --------
# OVERWRITE=1 means "do not skip": run even if a successful log exists.
OVERWRITE=0

# RESTART=1 means "if BASE.chk exists, generate a restart input using Geom=AllCheck Guess=Read".
RESTART=0

# ONLY_MISSING=1 means "run only if log file does not exist" (and do not overwrite existing logs).
ONLY_MISSING=0

# ONLY_FAILED=1 means "run only if log exists AND is NOT successful".
ONLY_FAILED=0

# Optional patch overrides. Empty string => do not change that property.
NPROC=""    # upserts %NProcShared
METHOD=""   # patches method in first X/Y token (requires BASIS if token missing)
BASIS=""    # patches basis  in first X/Y token (requires METHOD if token missing)
DISP=""     # upserts EmpiricalDispersion=...; use "none" to remove it

# -------- CLI parsing --------
# We parse flags until we hit a non-flag (which should be the input .com).
while [[ $# -gt 0 ]]; do
  case "$1" in
    # -o: overwrite / force run
    -o) OVERWRITE=1; shift ;;

    # --restart: attempt restart via .chk
    --restart) RESTART=1; shift ;;

    # run only if log missing
    --only-missing) ONLY_MISSING=1; shift ;;

    # run only if log exists but not successful
    --only-failed) ONLY_FAILED=1; shift ;;

    # -nproc <int>: patch %NProcShared=<int>
    -nproc) NPROC="${2:?ERROR: -nproc needs an int}"; shift 2 ;;

    # --method <value>: patch method part of METHOD/BASIS
    --method) METHOD="${2:?ERROR: --method needs a value}"; shift 2 ;;

    # --basis <value>: patch basis part of METHOD/BASIS
    --basis) BASIS="${2:?ERROR: --basis needs a value}"; shift 2 ;;

    # -d <value>: patch EmpiricalDispersion=<value> (or remove with "none")
    -d) DISP="${2:?ERROR: -d needs a value (e.g. GD3BJ or none)}"; shift 2 ;;

    # explicit end of options
    --) shift; break ;;

    # unknown option -> fail fast
    -*) echo "ERROR: unknown option: $1" >&2; exit 2 ;;

    # first non-option -> stop parsing (treat as INPUT)
    *) break ;;
  esac
done

# -------- input resolution --------
# First remaining argument must be the Gaussian input (.com)
INPUT="${1:?ERROR: missing input .com file}"
[[ -f "$INPUT" ]] || { echo "ERROR: input not found: $INPUT" >&2; exit 2; }

# Absolute working directory of the input file (important when called from elsewhere)
WORKDIR="$(cd "$(dirname "$INPUT")" && pwd)"

# Base name without .com extension
BASE="$(basename "$INPUT" .com)"

# Expected Gaussian log file path (same directory)
LOG="${WORKDIR}/${BASE}.log"

# Move to the work directory so all outputs land next to the input
cd "$WORKDIR"

# -------- helper --------
# Return success (exit 0) if log exists AND contains the normal termination string.
log_success() { [[ -f "$LOG" ]] && grep -q "Normal termination of Gaussian" "$LOG"; }

# -------- filter/skip policy --------
# NOTE: --only-missing and --only-failed are mutually exclusive by design.
if [[ "$ONLY_MISSING" -eq 1 && "$ONLY_FAILED" -eq 1 ]]; then
  echo "ERROR: --only-missing and --only-failed are mutually exclusive" >&2
  exit 2
fi

# If not overwriting, decide whether to skip based on flags + log state.
if [[ "$OVERWRITE" -eq 0 ]]; then
  if [[ "$ONLY_MISSING" -eq 1 ]]; then
    # Only run if the log is missing
    if [[ -f "$LOG" ]]; then
      echo "SKIP(--only-missing): $LOG exists"
      exit 0
    fi

  elif [[ "$ONLY_FAILED" -eq 1 ]]; then
    # Only run if the log exists but job didn't succeed
    if [[ ! -f "$LOG" ]]; then
      echo "SKIP(--only-failed): $LOG missing"
      exit 0
    fi
    if log_success; then
      echo "SKIP(--only-failed): already successful"
      exit 0
    fi

  else
    # Default policy: skip if already successful
    if log_success; then
      echo "SKIP: already successful"
      exit 0
    fi
  fi
fi

# -------- modules / gaussian --------
# Clean environment and load Gaussian module (common HPC pattern).
module purge
module load gaussian/g16

# Sanity check: ensure g16 is visible (fails early if module missing/misconfigured).
command -v g16 >/dev/null

# -------- scratch --------
# Gaussian uses GAUSS_SCRDIR for scratch files (integrals, temporary data, etc.).
# We build a scratch path that includes job id (SLURM) and PID to reduce collisions.
export GAUSS_SCRDIR="/scratch/${USER}/gauss_${SLURM_JOB_ID:-local}_$$"
mkdir -p "$GAUSS_SCRDIR"

# Ensure scratch is deleted on any exit (success or failure).
trap 'rm -rf "$GAUSS_SCRDIR"' EXIT

# -------- build input to run --------
# By default, we run the original input.
INPUT_TO_RUN="$INPUT"

# -------- restart logic --------
# If restart requested and BASE.chk exists, create a minimal restart input:
#   - Adds/ensures Geom=AllCheck and Guess=Read in the route section
#   - Preserves Link0 lines at the top
#   - Keeps just enough of the "title block" separation (two blank lines after route)
#
# IMPORTANT:
#   - This assumes the checkpoint file is BASE.chk.
#   - If your input uses a different checkpoint via %Chk=..., this script does NOT parse that yet.
CHK_GUESS="${WORKDIR}/${BASE}.chk"
if [[ "$RESTART" -eq 1 && -f "$CHK_GUESS" ]]; then
  TMP_RESTART="${BASE}.restart.com"

  python3 - "$INPUT" "$TMP_RESTART" <<'PY'
import sys, re

inp, outp = sys.argv[1], sys.argv[2]
# Read with tolerant error handling (avoids hard failures on odd encodings)
lines = open(inp, "r", encoding="utf-8", errors="replace").read().splitlines(True)

# Find the route section (# ...). We skip:
#   - Link0 lines (starting with %)
#   - blank lines
i = 0
while i < len(lines) and (lines[i].lstrip().startswith("%") or lines[i].strip() == ""):
    i += 1

if i >= len(lines) or not lines[i].lstrip().startswith("#"):
    raise SystemExit("ERROR: route section (#...) not found")

route_start = i
route_lines = []
# Gaussian allows multi-line route section as long as each line starts with '#'
while i < len(lines) and lines[i].lstrip().startswith("#"):
    route_lines.append(lines[i].rstrip("\n"))
    i += 1

# Flatten route into one line, add required restart keywords if absent.
route_text = " ".join(r.strip() for r in route_lines)
if "Geom=AllCheck" not in route_text:
    route_text += " Geom=AllCheck"
if "Guess=Read" not in route_text:
    route_text += " Guess=Read"
route_text = re.sub(r"\s+", " ", route_text).strip()

out = []
# Copy everything before route as-is (Link0, comments, etc.)
out.extend(lines[:route_start])
# Write the new single-line route
out.append(route_text + "\n")

# After the route, Gaussian expects:
#   blank line
#   title line(s)
#   blank line
#   charge/multiplicity or (when AllCheck) sometimes not needed, but keeping structure is safe.
# Here we just copy until we have seen two blank lines ("two blank-separated blocks").
rest = lines[i:]
blank_blocks = 0
for ln in rest:
    out.append(ln)
    if ln.strip() == "":
        blank_blocks += 1
        if blank_blocks >= 2:
            break

open(outp, "w", encoding="utf-8").write("".join(out))
PY

  INPUT_TO_RUN="$TMP_RESTART"
fi

# -------- patch overrides (UPSERT) --------
# If ANY override is provided, create a patched input file and run that.
# We patch:
#   1) %NProcShared
#   2) the first METHOD/BASIS token
#   3) EmpiricalDispersion
#
# The patch is intentionally conservative: it edits only what is requested.
if [[ -n "${NPROC}${METHOD}${BASIS}${DISP}" ]]; then
  TMP_PATCH="${BASE}.patched.com"

  python3 - "$INPUT_TO_RUN" "$TMP_PATCH" "$METHOD" "$BASIS" "$DISP" "$NPROC" <<'PY'
import sys, re

inp, outp, method, basis, disp, nproc = sys.argv[1:7]
method, basis, disp, nproc = method.strip(), basis.strip(), disp.strip(), nproc.strip()

lines = open(inp, "r", encoding="utf-8", errors="replace").read().splitlines(True)

# 1) UPSERT %NProcShared:
#    - If exists, replace
#    - Else insert at top
if nproc:
    nproc_line = f"%NProcShared={nproc}\n"
    for i, ln in enumerate(lines):
        if ln.lstrip().startswith("%NProcShared="):
            lines[i] = nproc_line
            break
    else:
        lines.insert(0, nproc_line)

# 2) Find route section (# ...)
i = 0
while i < len(lines) and (lines[i].lstrip().startswith("%") or lines[i].strip() == ""):
    i += 1
if i >= len(lines) or not lines[i].lstrip().startswith("#"):
    raise SystemExit("ERROR: route section (#...) not found")

route_start = i
route_lines = []
while i < len(lines) and lines[i].lstrip().startswith("#"):
    route_lines.append(lines[i].rstrip("\n"))
    i += 1

# Flatten multi-line route into one string for simple regex updates
route_text = " ".join(r.strip() for r in route_lines)
route_text = re.sub(r"\s+", " ", route_text).strip()

# 2a) UPSERT method/basis (first X/Y token):
# Matches e.g.: B3LYP/6-31G(d), PBE0/def2SVP, wB97X-D/def2TZVP, etc.
level_pat = re.compile(r"\b([A-Za-z][A-Za-z0-9\-\+]+)\s*/\s*([A-Za-z0-9][A-Za-z0-9\-\+\(\)\*]+)\b")

if method or basis:
    m = level_pat.search(route_text)
    if m:
        old_m, old_b = m.group(1), m.group(2)
        new_m = method or old_m
        new_b = basis  or old_b
        route_text = level_pat.sub(f"{new_m}/{new_b}", route_text, count=1)
    else:
        # If no METHOD/BASIS present, we only allow adding if BOTH are provided
        if not (method and basis):
            raise SystemExit("ERROR: no METHOD/BASIS token found; to add you must provide BOTH --method and --basis")
        route_text = f"{route_text} {method}/{basis}".strip()

# 2b) UPSERT EmpiricalDispersion=...
disp_pat = re.compile(r"\bEmpiricalDispersion\s*=\s*(\S+)\b", flags=re.IGNORECASE)
if disp:
    if disp.lower() == "none":
        # remove the keyword entirely
        route_text = disp_pat.sub("", route_text)
    else:
        # replace if present, otherwise append
        if disp_pat.search(route_text):
            route_text = disp_pat.sub(f"EmpiricalDispersion={disp}", route_text, count=1)
        else:
            route_text = f"{route_text} EmpiricalDispersion={disp}".strip()

route_text = re.sub(r"\s+", " ", route_text).strip()

# Write back route as a single line:
#   - replace the first route line
#   - delete any additional route lines previously present
lines[route_start] = route_text + "\n"
del lines[route_start+1:route_start+len(route_lines)]

open(outp, "w", encoding="utf-8").write("".join(lines))
PY

  INPUT_TO_RUN="$TMP_PATCH"
fi

# -------- status output --------
# Helpful for SLURM logs / debugging where the job actually ran.
echo "Host:    $(hostname)"
echo "Workdir: $WORKDIR"
echo "Input:   $INPUT_TO_RUN"
echo "Log:     $LOG"
echo "Scratch: $GAUSS_SCRDIR"

# -------- run gaussian --------
# Run Gaussian16:
#   g16 <input> <output>
#
# NOTE:
#   We write the output to BASE.log, regardless of whether INPUT_TO_RUN is patched/restart.
g16 "$INPUT_TO_RUN" "${BASE}.log"

# -------- post-run verification --------
# Double-check the log ends in "Normal termination".
# We look at the tail to keep it fast even for huge logs.
if ! tail -n 80 "$LOG" | grep -q "Normal termination of Gaussian"; then
  echo "ERROR: Gaussian did not finish normally: $LOG" >&2
  exit 4
fi

echo "OK: Normal termination"
