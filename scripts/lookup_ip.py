#!/usr/bin/env python3
"""Query the bundled global ip2region databases without network access."""

import argparse
import ipaddress
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "vendor" / "ip2region"))

from ip2region import searcher, util


def lookup(value):
    address = ipaddress.ip_address(value)
    if isinstance(address, ipaddress.IPv6Address) and address.ipv4_mapped:
        address = address.ipv4_mapped
    result = {"ip": value, "lookup_ip": str(address), "status": "non_public"}
    if not address.is_global or address.is_multicast:
        return result

    db_path = ROOT / "data" / "ip2region" / f"ip2region_v{address.version}.xdb"
    util.verify_from_file(str(db_path))
    header = util.load_header_from_file(str(db_path))
    version = util.version_from_header(header)
    expected = util.IPv4 if address.version == 4 else util.IPv6
    if version is None or version.id != expected.id:
        raise ValueError(f"database IP version mismatch: {db_path}")
    reader = searcher.new_with_file_only(version, str(db_path))
    try:
        region = reader.search(str(address))
    finally:
        reader.close()
    if not region:
        result["status"] = "not_found"
        return result
    fields = region.split("|")
    if len(fields) != 5:
        raise ValueError(f"unexpected database region format: {region!r}")
    result.update(dict(zip(
        ("country", "province", "city", "isp", "country_code"),
        (None if field in ("", "0") else field for field in fields),
    )))
    result.update(status="found", raw=region, source="ip2region/v3.18.0")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ips", nargs="+", help="IPv4 or IPv6 addresses")
    args = parser.parse_args()
    failed = False
    for value in args.ips:
        try:
            result = lookup(value)
        except (ValueError, OSError, IndexError, UnicodeError) as error:
            result = {"ip": value, "status": "error", "error": str(error)}
            failed = True
        print(json.dumps(result, ensure_ascii=False))
    return int(failed)


if __name__ == "__main__":
    sys.exit(main())
