#!/usr/bin/env python3
"""
gaussian2orca.py

Gaussian → ORCA compatibility wrapper
Focused on reproducing Gaussian MK/RESP workflows.

Supported:
- %Mem
- %NProcShared
- route line (# ...)
- Integral(Grid=UltraFine)
- Opt
- Pop(MK,ReadRadii)
- custom MK radii block
"""

import re
import sys
from pathlib import Path


# ==========================================================
# Gaussian parsing
# ==========================================================

def parse_gaussian(path: Path):

    lines = path.read_text().splitlines()

    mem = None
    nproc = None
    route = ""
    charge = None
    mult = None
    geom = []
    radii = {}

    i = 0
    while i < len(lines):
        line = lines[i].strip()

        if line.startswith("%Mem"):
            mem = line.split("=")[1]

        elif line.startswith("%NProcShared"):
            nproc = line.split("=")[1]

        elif line.startswith("#"):
            route = line

        elif re.match(r"^\s*-?\d+\s+-?\d+\s*$", line):
            charge, mult = line.split()
            i += 1

            # geometry
            while lines[i].strip():
                geom.append(lines[i])
                i += 1

            # optional radii block
            i += 1
            while i < len(lines):
                m = re.match(r"([A-Za-z]+)\s+([0-9.]+)", lines[i])
                if m:
                    radii[m.group(1)] = m.group(2)
                i += 1
            break

        i += 1

    return mem, nproc, route, charge, mult, geom, radii


# ==========================================================
# Route translation
# ==========================================================

def translate_route(route: str):

    method = "B3LYP"
    basis = "6-31G*"

    m = re.search(r"([A-Za-z0-9\-]+)/([A-Za-z0-9\-\*\+]+)", route)
    if m:
        method, basis = m.groups()

    keywords = [method, basis]

    if "Opt" in route:
        keywords.append("Opt")

    # UltraFine grid mapping
    if "UltraFine" in route:
        keywords += ["Grid5", "FinalGrid6"]

    # MK charges
    if "Pop(MK" in route:
        keywords.append("CHELPG")

    return "! " + " ".join(keywords)


# ==========================================================
# Memory conversion
# ==========================================================

def gaussian_mem_to_maxcore(mem, nproc):
    if not mem or not nproc:
        return None

    mb = int(re.findall(r"\d+", mem)[0])
    per_core = int((mb / int(nproc)) * 0.9)
    return per_core


# ==========================================================
# ORCA writer
# ==========================================================

def write_orca(outfile: Path, data):

    mem, nproc, route, charge, mult, geom, radii = data

    with outfile.open("w") as f:

        # ---- main keyword line ----
        f.write(translate_route(route) + "\n\n")

        # ---- parallel ----
        if nproc:
            f.write("%pal\n")
            f.write(f"  nprocs {nproc}\n")
            f.write("end\n\n")

        # ---- memory ----
        maxcore = gaussian_mem_to_maxcore(mem, nproc)
        if maxcore:
            f.write(f"%maxcore {maxcore}\n\n")

        # ---- SCF (Gaussian-like thresholds) ----
        f.write("%scf\n")
        f.write("  TolE    1e-9\n")
        f.write("  TolRMSP 5e-8\n")
        f.write("  TolMaxP 5e-7\n")
        f.write("  MaxIter 300\n")
        f.write("end\n\n")

        # ---- CHELPG radii ----
        if radii:
            f.write("%chelpg\n")
            for atom, r in radii.items():
                f.write(f"  AtomRadii {atom} {r}\n")
            f.write("end\n\n")

        # ---- geometry ----
        f.write(f"* xyz {charge} {mult}\n")
        for g in geom:
            f.write(g + "\n")
        f.write("*\n")


# ==========================================================
# Main
# ==========================================================

def main():

    if len(sys.argv) != 3:
        print("Usage: gaussian2orca.py input.com output.inp")
        sys.exit(1)

    inp = Path(sys.argv[1])
    out = Path(sys.argv[2])

    data = parse_gaussian(inp)
    write_orca(out, data)


if __name__ == "__main__":
    main()
