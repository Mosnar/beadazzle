# Third-Party Notices

Beadazzle currently resolves the following SwiftPM dependencies from `Package.resolved`.

## Swift Packages

| Component | Version | Upstream | License | Notes |
| --- | --- | --- | --- | --- |
| MarkdownEngine | `0.8.0` | `nodes-app/swift-markdown-engine` | Apache License 2.0 | Provides Beadazzle's markdown editing and rendering support. |
| HighlighterSwift | `3.1.0` | `smittytone/HighlighterSwift` | MIT License | Bundles additional Highlight.js code/theme portions under BSD 3-Clause terms, per upstream `LICENCE.md`. |
| SwiftMath | `1.7.3` | `mgriebling/SwiftMath` | MIT License | Includes bundled math fonts with upstream font-license notices. |

## Bundled Asset Notes

- `HighlighterSwift` upstream states that its wrapper code is MIT-licensed and that bundled Highlight.js portions are under the BSD 3-Clause license.
- `SwiftMath` upstream states that its distribution includes bundled fonts under the GUST Font License and SIL Open Font License / Open Font License, including:
  - Latin Modern Math — GUST Font License
  - TeX Gyre Termes — GUST Font License
  - XITS Math — Open Font License
  - KpMath Light / KpMath Sans — SIL Open Font License

## Source References

These notices were compiled from the pinned dependency checkouts used by this repository:

- `.build/checkouts/swift-markdown-engine/LICENSE`
- `.build/checkouts/HighlighterSwift/LICENCE.md`
- `.build/checkouts/SwiftMath/LICENSE`
- `.build/checkouts/SwiftMath/README.md`

For full and current license text, see each upstream repository.