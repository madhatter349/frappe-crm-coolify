#!/usr/bin/env python3
"""Create/refresh the Property DocType and upsert rows from a TSV export.

Usage:
    FRAPPE_API_KEY=... FRAPPE_API_SECRET=... \
        python3 scripts/import-properties.py properties.tsv

The TSV must carry the 107-column header exported from Actovia (see
scripts/property-doctype.json for the schema this creates). Existing records
are matched by BBL and updated in place.
"""
import csv
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

BASE = os.environ.get("FRAPPE_SITE", "https://frappe.forefrontinvestors.com").rstrip("/")
HDRS = {
    "Authorization": "token %s:%s" % (os.environ["FRAPPE_API_KEY"], os.environ["FRAPPE_API_SECRET"]),
    "Content-Type": "application/json",
}


def call(method, path, payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(BASE + path, data=data, headers=HDRS, method=method)
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return r.status, json.loads(r.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read().decode() or "{}")


DATE = {"DeedDateRec", "DeedDateActRaw", "DeedDateActual", "MtgeDateRec", "MtgeDateActual",
        "MtgeExpiration", "RatePPPChangeDate", "JudgmentMaxDate", "Contact1/AppDate",
        "Contact2/AppDate", "Contact3/AppDate"}
INT = {"Stories", "Units", "Lender/NrProperties", "Lender/NrDirectProperties", "Lender/NrLoans",
       "Lender/NrDirectLoans", "Lender/NrInCurrent", "Lender/TotalUnits", "Occupancy",
       "YearBuilt", "YearMod1", "YearMod2", "Grantee/NrProperties"}
FLOAT = {"SqFt", "LoanToValue", "MtgeRate", "CapRate", "FAR", "AvailableSqFt", "LotFront",
         "LotDepth", "LotSize"}
CURRENCY = {"DeedPrcPerUnit", "MtgePrcPerUnit", "DeedAmount", "MtgeAmount", "MtgePrcPerSqFt",
            "DeedPrcPerSqFt", "JudgmentMaxAmt", "Income", "Expense", "NOI", "FullVal"}
CHECK = {"PotentialSale", "IsPackage", "IsPurchase", "IsInConstruction", "IsLandmark",
         "HasSolar", "IsStar", "IsCollStar", "IsCondo", "IsCityOwned",
         "Contact1/IsOld", "Contact1/ContactHidden", "Contact1/PropContactHidden",
         "Contact2/IsOld", "Contact2/ContactHidden", "Contact2/PropContactHidden",
         "Contact3/IsOld", "Contact3/ContactHidden", "Contact3/PropContactHidden"}


def fname(col):
    n = col.replace("/", "_")
    n = re.sub(r"(?<=[a-z0-9])(?=[A-Z])", "_", n)
    n = re.sub(r"(?<=[A-Z])(?=[A-Z][a-z])", "_", n)
    return re.sub(r"[^a-z0-9_]+", "_", n.lower()).strip("_")


def value(col, raw):
    v = (raw or "").strip()
    if col in CHECK:
        return 1 if v.lower() == "true" else 0
    if v == "":
        return None
    if col in DATE:
        return v
    if col in INT:
        return int(float(v))
    if col in FLOAT or col in CURRENCY:
        return float(v)
    return v


def ensure_doctype():
    status, _ = call("GET", "/api/resource/DocType/Property")
    if status == 200:
        return
    here = os.path.dirname(os.path.abspath(__file__))
    schema = json.load(open(os.path.join(here, "property-doctype.json")))["data"]
    payload = {k: schema.get(k) for k in
               ("name", "module", "custom", "autoname", "title_field", "search_fields",
                "show_title_field_in_link", "fields", "permissions")}
    status, body = call("POST", "/api/resource/DocType", payload)
    if status >= 400:
        sys.exit("doctype create failed: %s %s" % (status, body))


def main(tsv):
    rows = list(csv.DictReader(open(tsv), delimiter="\t"))
    header = list(rows[0].keys())
    ensure_doctype()
    ok = fail = 0
    for r in rows:
        bbl = r["BBL"]
        data = {fname(c): value(c, r[c]) for c in header if c != "BBL"}
        data.update({"doctype": "Property", "bbl": bbl})
        status, body = call("POST", "/api/resource/Property", data)
        if status in (200, 201):
            ok += 1
            continue
        status, body = call("PUT", "/api/resource/Property/" + urllib.parse.quote(bbl), data)
        if status in (200, 201):
            ok += 1
        else:
            fail += 1
            print("FAIL", bbl, status, str(body)[:200])
    print("upserted=%d failed=%d" % (ok, fail))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
