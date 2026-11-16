#!/usr/bin/env python3
"""extract_trios.py KIN0 SEX_FILE OUT.ped

Extract parent-offspring trios from a KING kinship table (plink2 --make-king-table .kin0,
or KING's own .kin0) and a sex file with columns IID and SEX (1 = male, 2 = female).
Writes one line per trio, space-separated, no header:  child child father mother child_sex
(PED layout, read by bcftools +trio-stats and trio_stats_chrX.py).

A trio is a sample with two parent-offspring relatives of opposite sex who are not
related to each other (kinship below the 2nd-degree bound).
"""
import sys
from itertools import combinations
import pandas as pd

PO_KINSHIP = (0.177, 0.354)   # 1st-degree kinship range (KING)
PO_IBS0 = 0.0012              # parent-offspring have IBS0 below this; full siblings above (UK Biobank, Bycroft et al. 2018)
RELATED = 0.0884              # parents with kinship at or above this (2nd degree or closer) are not accepted

kin = pd.read_csv(sys.argv[1], sep=r"\s+", dtype=str)
kin.columns = kin.columns.str.lstrip("#").str.upper().str.replace(r"^ID", "IID", regex=True)
kin[["KINSHIP", "IBS0"]] = kin[["KINSHIP", "IBS0"]].astype(float)
sex = pd.read_csv(sys.argv[2], sep=r"\s+", dtype=str)
sex.columns = sex.columns.str.lstrip("#")
sex = dict(zip(sex["IID"], sex["SEX"]))

related = set(map(frozenset, kin.loc[kin.KINSHIP >= RELATED, ["IID1", "IID2"]].values))
po = kin[kin.KINSHIP.between(*PO_KINSHIP) & (kin.IBS0 < PO_IBS0)]
po_relatives = {}
for a, b in po[["IID1", "IID2"]].values:
    po_relatives.setdefault(a, []).append(b)
    po_relatives.setdefault(b, []).append(a)

n = 0
with open(sys.argv[3], "w") as out:
    for child, rel in po_relatives.items():
        parents = [p for p in combinations(rel, 2)
                   if frozenset(p) not in related and {sex.get(p[0]), sex.get(p[1])} == {"1", "2"}]
        if len(parents) == 1:
            father, mother = sorted(parents[0], key=lambda s: sex[s])
            out.write(f"{child} {child} {father} {mother} {sex.get(child, '0')}\n")
            n += 1
print(f"extract_trios.py: {len(po)} parent-offspring pairs, {n} trios", file=sys.stderr)
