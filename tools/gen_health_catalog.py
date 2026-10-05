#!/usr/bin/env python3
"""Regenerate apps/ios/OuraApp/HealthCatalog.swift from the iOS SDK's HealthKit header.

Run it after an Xcode update to pick up new HealthKit types:
    python3 tools/gen_health_catalog.py
"""
import pathlib
import re
import subprocess

REPO = pathlib.Path(__file__).resolve().parent.parent
sdk = subprocess.check_output(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"]).decode().strip()
header = pathlib.Path(sdk, "System/Library/Frameworks/HealthKit.framework/Headers/HKTypeIdentifiers.h").read_text()
quantity = sorted(set(re.findall(r"HKQuantityTypeIdentifier const (HKQuantityTypeIdentifier\w+)", header)))
category = sorted(set(re.findall(r"HKCategoryTypeIdentifier const (HKCategoryTypeIdentifier\w+)", header)))


def block(name, items):
    return f"    static let {name}: [String] = [\n" + "".join(f'        "{i}",\n' for i in items) + "    ]\n"


version = sdk.split("iPhoneOS")[-1].replace(".sdk", "") or "current"
out = f"""// Generated from HealthKit's HKTypeIdentifiers.h (iOS SDK {version}) by
// tools/gen_health_catalog.py. Every quantity and category identifier, by raw value, so
// an identifier that this iOS version does not have simply resolves to nil.
enum HealthCatalog {{
{block("quantity", quantity)}
{block("category", category)}}}
"""
(REPO / "apps/ios/OuraApp/HealthCatalog.swift").write_text(out)
print(f"{len(quantity)} quantity and {len(category)} category identifiers")
