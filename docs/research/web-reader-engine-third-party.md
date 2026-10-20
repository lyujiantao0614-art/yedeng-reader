# Pinned Web reader third-party assets

Public license/provenance extract for the packaged epub.js and JSZip assets. This file records distribution inputs and hashes; it does not publish private device research or claim fresh runtime acceptance. Assets are bundled locally and are not fetched at runtime.

## epub.js

- Package: `epubjs`
- Version: `0.3.93`
- Role: pinned initial EPUB renderer accepted by the completed Phase 0B plan
- License: BSD-2-Clause
- Package source:
  `https://registry.npmjs.org/epubjs/-/epubjs-0.3.93.tgz`
- Upstream source tag:
  `https://github.com/futurepress/epub.js/tree/v0.3.93`
- npm package SHA-512 integrity:
  `sha512-c06pNSdBxcXv3dZSbXAVLE1/pmleRhOT6mXNZo6INKmvuKpYB65MwU/lO7830czCtjIiK9i+KR+3S+p0wtljrw==`
- Downloaded package SHA-256:
  `180B33059CA15E2B4F129EB7FEF6CAE0BF6005C02AF5194D13E5CB48378D538F`

Vendored files:

| File | SHA-256 |
| --- | --- |
| `entry/src/main/resources/rawfile/web-reader/vendor/epubjs-0.3.93/epub.min.js` | `06EAE15745107B4AA508C95538275251F69BFB9F1175621FC458D9F42ED082D4` |
| `entry/src/main/resources/rawfile/web-reader/vendor/epubjs-0.3.93/LICENSE` | `8663E726F4194E1A34913B223C2E4745ED06F3EC645A66A41AB70B735070B692` |

The vendored files are unmodified copies of `package/dist/epub.min.js` and
`package/license` from the npm tarball.

## JSZip

- Package: `jszip`
- Version: `3.10.1`
- Role: archive dependency used by epub.js to open packaged `.epub` files
- License: MIT OR GPL-3.0-or-later; this project uses the MIT option
- Package source:
  `https://registry.npmjs.org/jszip/-/jszip-3.10.1.tgz`
- Upstream source tag:
  `https://github.com/Stuk/jszip/tree/v3.10.1`
- npm package SHA-512 integrity:
  `sha512-xXDvecyTpGLrqFrvkrUSoxxfJI5AH7U8zxxtVclpsUtMCq4JQ290LY8AW5c7Ggnr/Y/oK+bQMbqK2qmtk3pN4g==`
- Downloaded package SHA-256:
  `5117F4A2A645AEB307BF3B829C575AD58135CC97E75291E594532AB5B5B21B23`

Vendored files:

| File | SHA-256 |
| --- | --- |
| `entry/src/main/resources/rawfile/web-reader/vendor/jszip-3.10.1/jszip.min.js` | `ACC7E41455A80765B5FD9C7EE1B8078A6D160BBBCA455AEAE854DE65C947D59E` |
| `entry/src/main/resources/rawfile/web-reader/vendor/jszip-3.10.1/LICENSE.markdown` | `566C953C6090B1218CA6217DD7359D45DDE46581968586DC607D59A78AF6A9C4` |

The vendored files are unmodified copies of `package/dist/jszip.min.js` and
`package/LICENSE.markdown` from the npm tarball.

## Local verification

From the repository root:

```powershell
Get-ChildItem -Recurse -File entry/src/main/resources/rawfile/web-reader/vendor |
  Get-FileHash -Algorithm SHA256
```

Compare all four results with the tables above. A hash mismatch means the
asset must not be used until its provenance is reviewed and this record is
updated intentionally.

