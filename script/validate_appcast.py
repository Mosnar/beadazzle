#!/usr/bin/env python3
"""Validate that a generated Sparkle appcast publishes the intended release."""

from __future__ import annotations

import argparse
import re
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path


SPARKLE_NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
VERSION_ATTRIBUTE = f"{{{SPARKLE_NAMESPACE}}}version"
SHORT_VERSION_ATTRIBUTE = f"{{{SPARKLE_NAMESPACE}}}shortVersionString"
VERSION_ELEMENT = f"{{{SPARKLE_NAMESPACE}}}version"
SHORT_VERSION_ELEMENT = f"{{{SPARKLE_NAMESPACE}}}shortVersionString"
CHANNEL_ELEMENT = f"{{{SPARKLE_NAMESPACE}}}channel"


@dataclass(frozen=True)
class AppcastItem:
    version: str
    short_version: str
    channel: str | None
    download_url: str


def normalized_release_tag(release_tag: str) -> str:
    tag = release_tag.removeprefix("refs/tags/")
    return tag.removeprefix("v")


def expected_short_version(release_tag: str) -> str:
    normalized_tag = normalized_release_tag(release_tag)
    match = re.fullmatch(
        r"(?P<version>[0-9]+\.[0-9]+\.[0-9]+)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?",
        normalized_tag,
    )
    if match is None:
        raise ValueError(f"release tag is not semantic versioning: {release_tag}")
    return match.group("version")


def build_version_key(version: str) -> tuple[int, int, int]:
    parts = version.split(".")
    if not 1 <= len(parts) <= 3 or any(not part.isdigit() for part in parts):
        raise ValueError(f"invalid Sparkle build version: {version}")
    return tuple(int(part) for part in parts) + (0,) * (3 - len(parts))


def load_items(appcast_path: str) -> list[AppcastItem]:
    if appcast_path == "-":
        root = ET.parse(sys.stdin).getroot()
    else:
        root = ET.parse(Path(appcast_path)).getroot()

    items: list[AppcastItem] = []
    for item_element in root.findall("./channel/item"):
        enclosure = item_element.find("enclosure")
        if enclosure is None:
            continue
        version = enclosure.get(VERSION_ATTRIBUTE) or item_element.findtext(VERSION_ELEMENT)
        short_version = enclosure.get(SHORT_VERSION_ATTRIBUTE) or item_element.findtext(
            SHORT_VERSION_ELEMENT
        )
        download_url = enclosure.get("url")
        if not version or not short_version or not download_url:
            raise ValueError("appcast item enclosure is missing version metadata or URL")
        channel = item_element.findtext(CHANNEL_ELEMENT)
        items.append(
            AppcastItem(
                version=version,
                short_version=short_version,
                channel=channel,
                download_url=download_url,
            )
        )
    if not items:
        raise ValueError("appcast contains no update items")
    return items


def validate_appcast(
    appcast_path: str,
    release_tag: str,
    build_number: str,
) -> None:
    items = load_items(appcast_path)
    normalized_tag = normalized_release_tag(release_tag)
    tag_path = f"/releases/download/{release_tag.removeprefix('refs/tags/')}/"
    matching_items = [item for item in items if tag_path in item.download_url]
    if len(matching_items) != 1:
        raise ValueError(
            f"expected exactly one appcast item for {release_tag}; found {len(matching_items)}"
        )

    current_item = matching_items[0]
    expected_channel = "beta" if "-" in normalized_tag.split("+", 1)[0] else None
    if current_item.version != build_number:
        raise ValueError(
            f"appcast build {current_item.version} does not match packaged build {build_number}"
        )
    expected_short = expected_short_version(release_tag)
    if current_item.short_version != expected_short:
        raise ValueError(
            f"appcast short version {current_item.short_version} does not match release {expected_short}"
        )
    if current_item.channel != expected_channel:
        rendered_channel = current_item.channel or "stable"
        expected_rendered_channel = expected_channel or "stable"
        raise ValueError(
            f"appcast channel {rendered_channel} does not match expected {expected_rendered_channel}"
        )

    current_build = build_version_key(current_item.version)
    for retained_item in items:
        if retained_item is current_item:
            continue
        if build_version_key(retained_item.version) >= current_build:
            raise ValueError(
                "new release build must be newer than every retained appcast item: "
                f"{retained_item.version} >= {current_item.version}"
            )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--appcast", required=True, help="appcast XML path, or - for stdin")
    parser.add_argument("--release-tag", required=True)
    parser.add_argument("--build-number", required=True)
    arguments = parser.parse_args()

    try:
        validate_appcast(
            appcast_path=arguments.appcast,
            release_tag=arguments.release_tag,
            build_number=arguments.build_number,
        )
    except (ET.ParseError, OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    print(
        f"Validated {arguments.release_tag} build {arguments.build_number} as the newest appcast item",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
