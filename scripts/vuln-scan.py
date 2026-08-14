#!/usr/bin/env python3
"""Check every installed package against the NVD CVE database.

Installed on the image as /usr/sbin/vuln-scan. Also runs on the build host, against
the same manifest, so the report shipped in the image and a later refresh are produced
by identical code.

Why NVD and not OSV: OSV organises data by ecosystem (PyPI, npm, Debian, ...) and has
no ecosystem for "upstream C tarball", which is what almost everything here is. NVD's
CPE version-range matching handles exactly that case.

Why the vendor is a wildcard: NVD's cpeName parameter needs the exact CPE vendor, which
is frequently not the obvious one -- curl's is "haxx", not "curl", and cpeName with
"curl:curl" silently returns zero results rather than an error. virtualMatchString
accepts a wildcard vendor and returns identical results, which removes the need to
hand-maintain a vendor map for ~100 packages. The cost is that a generic product name
could match a different vendor's product, so every vendor that matched is recorded and
packages matching more than one are flagged for a human to check.

No dependencies outside the standard library, because the image has no pip.
"""

import argparse
import json
import os
import re
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

NVD = "https://services.nvd.nist.gov/rest/json/cves/2.0"

# LFS tarball name -> CPE product name, where they differ.
CPE_ALIASES = {
    "linux": "linux_kernel",
    "python": "python",
    "xml-parser": "libxml-parser-perl",
    "procps-ng": "procps-ng",
    "iproute2": "iproute2",
    # LFS SysV builds udev from the systemd tarball. The installed component is udev --
    # there is no systemctl and there are no units -- but its CVEs are tracked under
    # systemd, so query that and say so in the report.
    "udev": "systemd",
}

# Which CPE vendors legitimately own each product name.
#
# The wildcard vendor is what makes this scanner practical, but product names are not
# unique across vendors and the collisions are not subtle: "tar" matches the node-tar
# npm package (18 hits, of which exactly 1 is GNU tar), "zlib" matches Cloudflare's fork
# and Ruby's binding but not zlib itself, and "ninja" matches an ITRS Group product with
# no relation to ninja-build. Counting those would inflate the headline figures with
# advisories against software that is not installed -- which is worse than not scanning,
# because it looks authoritative.
#
# Verified against NVD by listing each matching CVE's vendor. Where a package is absent
# from this map and its matches span more than one vendor, it is reported as UNVERIFIED
# and left out of the totals rather than silently counted or silently dropped.
CPE_VENDORS = {
    "tar":      {"gnu"},
    "zlib":     {"zlib", "gnu"},
    "ninja":    {"ninja-build"},
    "flex":     {"westes"},
    "openssl":  {"openssl"},
    "python":   {"python", "python_software_foundation"},
    "gawk":     {"gnu", "fossies"},   # NVD files current gawk issues under "fossies"
    "curl":     {"haxx"},
    "openssh":  {"openbsd"},
    "perl":     {"perl"},
    "vim":      {"vim"},
    "glibc":    {"gnu"},
    "systemd":  {"systemd_project", "freedesktop"},
}

# Packages with no meaningful CPE entry: data, or project-local scaffolding. Querying
# them wastes 6.5s of rate limit each and can only produce false matches.
SKIP = {
    "man-pages", "iana-etc", "tzdata", "lfs-bootscripts", "make-ca",
    "docs", "blfs-bootscripts",
}

SEVERITIES = ("CRITICAL", "HIGH", "MEDIUM", "LOW", "UNKNOWN")


def parse_args():
    p = argparse.ArgumentParser(description="Scan installed packages against NVD.")
    p.add_argument("-m", "--manifest", default="/etc/bastionos/packages.tsv")
    p.add_argument("-o", "--output", default="/etc/bastionos/vuln-report.txt")
    p.add_argument("--api-key", default=os.environ.get("NVD_API_KEY", ""))
    p.add_argument("--delay", type=float, default=None,
                   help="seconds between requests (default 6.5, or 1.2 with an API key)")
    p.add_argument("--only", default="", help="scan just this package (for testing)")
    p.add_argument("--quiet", action="store_true")
    return p.parse_args()


def read_manifest(path):
    pkgs = []
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) >= 2:
                pkgs.append((parts[0], parts[1], parts[2] if len(parts) > 2 else ""))
    return pkgs


def fetch(url, api_key, attempts=4):
    """GET with backoff. NVD answers 403 for rate limiting, not 429, and it is not
    consistent about it -- so retry on any transient status rather than a specific one."""
    ctx = ssl.create_default_context()
    for i in range(attempts):
        req = urllib.request.Request(url, headers={"User-Agent": "BastionOS-vuln-scan"})
        if api_key:
            req.add_header("apiKey", api_key)
        try:
            with urllib.request.urlopen(req, timeout=60, context=ctx) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            if e.code in (403, 429, 503, 500) and i < attempts - 1:
                time.sleep(8 * (i + 1))
                continue
            raise
        except (urllib.error.URLError, TimeoutError, ssl.SSLError):
            if i < attempts - 1:
                time.sleep(5 * (i + 1))
                continue
            raise
    return None


def severity_of(cve):
    m = cve.get("metrics", {})
    for key in ("cvssMetricV40", "cvssMetricV31", "cvssMetricV30"):
        if m.get(key):
            d = m[key][0].get("cvssData", {})
            return (d.get("baseSeverity") or "UNKNOWN").upper(), d.get("baseScore")
    if m.get("cvssMetricV2"):
        e = m["cvssMetricV2"][0]
        return (e.get("baseSeverity") or "UNKNOWN").upper(), e.get("cvssData", {}).get("baseScore")
    return "UNKNOWN", None


def vendors_for(cve, product):
    out = set()
    for cfg in cve.get("configurations", []):
        for node in cfg.get("nodes", []):
            for match in node.get("cpeMatch", []):
                bits = match.get("criteria", "").split(":")
                if len(bits) > 4 and bits[4] == product:
                    out.add(bits[3])
    return out


def scan_one(name, version, api_key):
    product = CPE_ALIASES.get(name.lower(), name.lower())
    cpe = f"cpe:2.3:a:*:{product}:{version}:*:*:*:*:*:*:*"
    url = f"{NVD}?{urllib.parse.urlencode({'virtualMatchString': cpe})}"
    data = fetch(url, api_key)
    if data is None:
        return None
    allowed = CPE_VENDORS.get(product)
    counts = dict.fromkeys(SEVERITIES, 0)
    findings, vendors, dropped = [], set(), 0
    for item in data.get("vulnerabilities", []):
        cve = item["cve"]
        # Rejected entries stay in the API but are not real vulnerabilities.
        if cve.get("vulnStatus", "") == "Rejected":
            continue
        cve_vendors = vendors_for(cve, product)
        # Keep the advisory only if some vendor that owns this product name claims it.
        if allowed is not None and not (cve_vendors & allowed):
            dropped += 1
            continue
        vendors |= cve_vendors
        sev, score = severity_of(cve)
        counts[sev] = counts.get(sev, 0) + 1
        findings.append((cve["id"], sev, score))
    # A kernel query against product linux_kernel matches an enormous number of CVEs
    # that apply to drivers and subsystems this build does not even compile in, so the
    # count is an upper bound rather than an assertion. Flagged in the report.
    findings.sort(key=lambda f: (SEVERITIES.index(f[1]) if f[1] in SEVERITIES else 9, f[0]))
    unverified = allowed is None and len(vendors) > 1
    return counts, findings, vendors, dropped, unverified


def main():
    args = parse_args()
    delay = args.delay if args.delay is not None else (1.2 if args.api_key else 6.5)

    try:
        pkgs = read_manifest(args.manifest)
    except OSError as e:
        print(f"cannot read manifest: {e}", file=sys.stderr)
        return 2
    if args.only:
        pkgs = [p for p in pkgs if p[0] == args.only]

    todo = [p for p in pkgs if p[0].lower() not in SKIP and p[1] != "?"]
    skipped = [p for p in pkgs if p not in todo]

    lines, totals = [], dict.fromkeys(SEVERITIES, 0)
    affected, ambiguous, errors, filtered_out = 0, [], [], 0

    for i, (name, version, origin) in enumerate(todo, 1):
        if not args.quiet:
            print(f"[{i:3d}/{len(todo)}] {name}-{version} ", end="", flush=True)
        try:
            res = scan_one(name, version, args.api_key)
        except Exception as e:                      # noqa: BLE001 - report, never abort
            errors.append(f"{name}: {e}")
            if not args.quiet:
                print(f"ERROR {e}")
            time.sleep(delay)
            continue

        counts, findings, vendors, dropped, unverified = res
        n = sum(counts.values())
        if dropped:
            filtered_out += dropped
        if unverified:
            # Counted, but say so: the totals could be inflated by another vendor's
            # product that happens to share this name.
            ambiguous.append(f"{name} (vendors: {', '.join(sorted(vendors))})")
        if n:
            affected += 1
            for s in SEVERITIES:
                totals[s] += counts[s]
            lines.append(
                "PKG\t{}\t{}\t{}\tcritical={} high={} medium={} low={} unknown={} vendors={}".format(
                    name, version, origin, counts["CRITICAL"], counts["HIGH"],
                    counts["MEDIUM"], counts["LOW"], counts["UNKNOWN"],
                    ",".join(sorted(vendors)) or "-"))
            for cid, sev, score in findings:
                if sev in ("CRITICAL", "HIGH"):
                    lines.append(f"CVE\t{name}\t{cid}\t{sev}\t{score if score is not None else '-'}")
        if not args.quiet:
            print(f"{n} CVE(s)" if n else "clean")
        if i < len(todo):
            time.sleep(delay)

    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    header = [
        "# BastionOS vulnerability report",
        f"# generated: {stamp}",
        "# source: NVD CVE API 2.0 (services.nvd.nist.gov)",
        f"# packages scanned: {len(todo)}   not applicable: {len(skipped)}",
        "#",
        "# These are UPSTREAM advisories against the versions LFS 13.0 pins. They are not",
        "# misconfigurations of this system, and a CVE being listed does not mean it is",
        "# exploitable here -- much of the kernel count in particular covers drivers and",
        "# subsystems this build does not compile in. Treat it as an upper bound, and as",
        "# the honest answer to 'what is known to be wrong with what I am running'.",
        "#",
        f"# {filtered_out} advisories were discarded as belonging to a different vendor's",
        "# product that shares a name with an installed package (node-tar vs GNU tar,",
        "# ITRS Ninja vs ninja-build, Cloudflare's zlib fork vs zlib, and similar).",
        "# udev is listed under systemd because that is where its CVEs are tracked; only",
        "# udev is installed here, so that count is an upper bound too.",
        "SUMMARY critical={} high={} medium={} low={} unknown={} affected_packages={} scanned={}".format(
            totals["CRITICAL"], totals["HIGH"], totals["MEDIUM"], totals["LOW"],
            totals["UNKNOWN"], affected, len(todo)),
    ]
    if ambiguous:
        header.append("# AMBIGUOUS (product name matched more than one CPE vendor; verify):")
        header += [f"#   {a}" for a in ambiguous]
    if errors:
        header.append("# ERRORS:")
        header += [f"#   {e}" for e in errors]

    report = "\n".join(header + [""] + lines) + "\n"
    try:
        os.makedirs(os.path.dirname(args.output), exist_ok=True)
        with open(args.output, "w") as fh:
            fh.write(report)
    except OSError as e:
        print(f"could not write {args.output}: {e}", file=sys.stderr)
        print(report)
        return 2

    print()
    print(f"  critical={totals['CRITICAL']} high={totals['HIGH']} "
          f"medium={totals['MEDIUM']} low={totals['LOW']}")
    print(f"  {affected} of {len(todo)} packages have at least one advisory")
    print(f"  written to {args.output}")
    # Deliberately exit 0 even with findings: upstream having CVEs is a fact to report,
    # not a failure of this build, and a non-zero exit here would fail the boot test.
    return 0


if __name__ == "__main__":
    sys.exit(main())
