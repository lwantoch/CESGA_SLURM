# CESGA_SLURM

Utilities for running **Gaussian** and **ORCA** quantum chemistry calculations on the **CESGA FinisTerrae III (SLURM)** cluster.

This repository provides:

- robust SLURM submitters
- reproducible single-job runners
- Gaussian → ORCA input conversion
- automation-friendly execution logic (idempotent runs, restart handling)

The goal is **reproducible large-scale QM workflows**, especially for batch calculations and parameterisation pipelines.

---

## Overview

Typical workflow:

Gaussian input (.com)
        ↓
gaussian2orca.py
        ↓
ORCA input (.inp)
        ↓
submit_orca.sh
        ↓
run_orca.sh (SLURM worker)
        ↓
ORCA calculation

The scripts are designed for:

- HPC environments
- large job arrays
- automated pipelines
- restart-safe execution
- consistent numerical settings

---

## Repository Structure

```
CESGA_SLURM/
│
├── gaussian2orca.py      # Gaussian → ORCA conversion wrapper
├── run_gaussian.sh       # Gaussian worker (single calculation)
├── run_orca.sh           # ORCA worker (robust execution script)
├── submit_gaussian.sh    # SLURM submitter (single + array mode)
├── submit_orca.sh        # SLURM submitter for ORCA
└── README.md
```

---

## Design Philosophy

The scripts separate responsibilities:

| Layer | Responsibility |
|------|---------------|
| submit_* | job discovery + SLURM submission |
| run_* | execution of one calculation |
| python wrapper | input translation / reproducibility |

This separation allows:

- safe job arrays
- restartable workflows
- easy automation
- deterministic behaviour

---

## Gaussian → ORCA Conversion

`gaussian2orca.py` is **not just a syntax converter**.  
It attempts to reproduce Gaussian calculations numerically where possible.

Currently supported features:

- `%Mem` → `%maxcore`
- `%NProcShared` → `%pal nprocs`
- route line translation (`# B3LYP/6-31G* ...`)
- `Integral(Grid=UltraFine)` → `Grid5 FinalGrid6`
- `Pop(MK,ReadRadii)` → `CHELPG`
- custom MK radii blocks (e.g. metal centres)
- Gaussian-like SCF convergence thresholds

Example:

```
python gaussian2orca.py job.com job.inp
```

---

## Running ORCA Jobs

### Single job

```
./submit_orca.sh calculation.inp
```

### Recursive submission (job array)

```
./submit_orca.sh -r -p "*.inp" data/
```

---

## Execution Policy

Jobs are **idempotent by default**:

- successful outputs are skipped
- failed jobs can be selectively rerun
- overwrite must be explicit

Options:

| Option | Meaning |
|---|---|
| `-o` | overwrite existing outputs |
| `--only-missing` | run only missing jobs |
| `--only-failed` | rerun failed calculations |
| `--restart` | attempt restart from previous wavefunction |

---

## Numerical Consistency

ORCA inputs generated aim to approximate:

Gaussian:

```
B3LYP/6-31G*
Integral(Grid=UltraFine)
Pop(MK,ReadRadii)
```

via:

ORCA:

```
Grid5 FinalGrid6
CHELPG
explicit SCF thresholds
```

Exact numerical identity between programs is not expected, but results should be chemically equivalent.

---

## Requirements

### Cluster

- SLURM scheduler
- ORCA module available or user installation
- Gaussian (optional)

### Software

- bash
- python ≥ 3.8

No external Python dependencies required.

---

## Recommended Filesystem Usage (FinisTerrae III)

| Purpose | Location |
|---|---|
| software installs | `$STORE` |
| input/output | project directory |
| temporary files | `/scratch/$USER` |

`run_orca.sh` automatically configures scratch usage.

---

## Example Workflow

```
# convert Gaussian input
python gaussian2orca.py zn_site.com zn_site.inp

# submit calculation
./submit_orca.sh zn_site.inp
```

---

## Intended Use Cases

- metal parameterisation (RESP / MCPB workflows)
- large ligand libraries
- QM batch optimisation
- Gaussian → ORCA migration
- HPC automation pipelines

---

## Disclaimer

This repository focuses on **practical reproducibility**, not exact program equivalence.  
Different quantum chemistry codes may produce small numerical differences even under identical theoretical settings.

---

## Author

Lukasz Wantoch  
Computational Chemistry / Molecular Simulation
