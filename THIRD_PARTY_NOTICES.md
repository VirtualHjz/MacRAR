# Third-party notices

The root MIT license applies to MacRAR's original code. The following bundled
components have separate terms:

| Component | Location | License and notice |
| --- | --- | --- |
| UnRAR source | `Sources/CUnrar/sources/` and `ThirdParty/unrar/` | RARLAB's UnRAR license. It permits use for handling RAR archives but prohibits use to develop a RAR-compatible compressor or recreate the proprietary compression algorithm. Full text: [ThirdParty/unrar/license.txt](ThirdParty/unrar/license.txt). |
| p7zip 16.02 source and 7za | `ThirdParty/p7zip_16.02/`, `Sources/MacRAR/Resources/bin/7za` | LGPL 2.1 or later, with the UnRAR restriction for specified RAR-related files. Full texts: [License.txt](ThirdParty/p7zip_16.02/DOC/License.txt), [copying.txt](ThirdParty/p7zip_16.02/DOC/copying.txt), [unRarLicense.txt](ThirdParty/p7zip_16.02/DOC/unRarLicense.txt). |

RARLAB's proprietary `rar` archiver is **not** included in this repository or
the release package. RAR creation requires users to install and license that
tool separately. The optional RAR creation fixtures in
`Scripts/test_release.sh` run only when a local `rar` tool is available.
