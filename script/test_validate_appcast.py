#!/usr/bin/env python3

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from validate_appcast import validate_appcast


def appcast_item(
    *,
    tag: str,
    version: str,
    short_version: str,
    channel: str | None = None,
    metadata_on_enclosure: bool = False,
) -> str:
    channel_xml = f"<sparkle:channel>{channel}</sparkle:channel>" if channel else ""
    if metadata_on_enclosure:
        metadata_xml = ""
        enclosure_metadata = (
            f'sparkle:version="{version}" '
            f'sparkle:shortVersionString="{short_version}"'
        )
    else:
        metadata_xml = (
            f"<sparkle:version>{version}</sparkle:version>"
            f"<sparkle:shortVersionString>{short_version}</sparkle:shortVersionString>"
        )
        enclosure_metadata = ""
    return f"""
    <item>
      <title>{short_version}</title>
      {channel_xml}
      {metadata_xml}
      <enclosure
        url="https://github.com/Mosnar/beadazzle/releases/download/{tag}/Beadazzle.dmg"
        {enclosure_metadata} />
    </item>
    """


class ValidateAppcastTests(unittest.TestCase):
    def write_appcast(self, *items: str) -> str:
        contents = f"""<?xml version="1.0" encoding="utf-8"?>
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel>{''.join(items)}</channel>
        </rss>
        """
        temporary_file = tempfile.NamedTemporaryFile(mode="w", suffix=".xml", delete=False)
        self.addCleanup(Path(temporary_file.name).unlink, missing_ok=True)
        with temporary_file:
            temporary_file.write(contents)
        return temporary_file.name

    def test_accepts_newest_stable_release(self) -> None:
        appcast = self.write_appcast(
            appcast_item(tag="v1.3.0", version="12", short_version="1.3.0"),
            appcast_item(tag="v1.2.0", version="11", short_version="1.2.0"),
        )

        validate_appcast(appcast, "v1.3.0", "12")

    def test_accepts_beta_release_on_beta_channel(self) -> None:
        appcast = self.write_appcast(
            appcast_item(
                tag="v1.4.0-beta.1",
                version="13",
                short_version="1.4.0",
                channel="beta",
            ),
            appcast_item(tag="v1.3.0", version="12", short_version="1.3.0"),
        )

        validate_appcast(appcast, "v1.4.0-beta.1", "13")

    def test_accepts_enclosure_attribute_metadata(self) -> None:
        appcast = self.write_appcast(
            appcast_item(
                tag="v1.3.0",
                version="12",
                short_version="1.3.0",
                metadata_on_enclosure=True,
            ),
        )

        validate_appcast(appcast, "v1.3.0", "12")

    def test_rejects_release_that_is_not_newest_build(self) -> None:
        appcast = self.write_appcast(
            appcast_item(tag="v1.3.0", version="12", short_version="1.3.0"),
            appcast_item(tag="v1.2.0", version="13", short_version="1.2.0"),
        )

        with self.assertRaisesRegex(ValueError, "newer than every retained"):
            validate_appcast(appcast, "v1.3.0", "12")

    def test_rejects_mismatched_short_version(self) -> None:
        appcast = self.write_appcast(
            appcast_item(tag="v1.3.0", version="12", short_version="1.2.0"),
        )

        with self.assertRaisesRegex(ValueError, "short version"):
            validate_appcast(appcast, "v1.3.0", "12")

    def test_rejects_stable_release_on_beta_channel(self) -> None:
        appcast = self.write_appcast(
            appcast_item(
                tag="v1.3.0",
                version="12",
                short_version="1.3.0",
                channel="beta",
            ),
        )

        with self.assertRaisesRegex(ValueError, "channel beta"):
            validate_appcast(appcast, "v1.3.0", "12")


if __name__ == "__main__":
    unittest.main()
