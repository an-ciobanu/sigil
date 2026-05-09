#!/usr/bin/env bash
# Pinned vexscan version. Bumping these is a deliberate, reviewable change:
# the upstream commit MUST be re-audited before changing the SHA.
#
# Trust anchors:
#   - VEXSCAN_PIN_COMMIT           — content-addresses the source we audited.
#   - sibling Cargo.lock           — fixes the entire transitive dep tree
#                                    for the source-build fallback path.
#   - sibling checksums.txt        — sha256 of each pre-built release artifact
#                                    for the fast download path.
#
# Bump procedure:
#   1. Audit the new vexscan source at the target SHA.
#   2. Update VEXSCAN_PIN_COMMIT below.
#   3. Regenerate Cargo.lock from a fresh clone:
#        git clone https://github.com/edimuj/vexscan /tmp/vexscan-bump
#        git -C /tmp/vexscan-bump checkout <new_sha>
#        (cd /tmp/vexscan-bump && cargo generate-lockfile)
#        cp /tmp/vexscan-bump/Cargo.lock scripts/lib/vexscan/Cargo.lock
#   4. With the new pin.sh + Cargo.lock already in place from steps 2-3,
#      build the release binary for each supported platform:
#        SIGIL_VEXSCAN_FROM_SOURCE=1 SIGIL_STATE_DIR=/tmp/sigil-bump \
#          ./scripts/sigil-bootstrap-vexscan.sh
#        cp /tmp/sigil-bump/vexscan/vexscan-<short_sha> \
#          ./release/vexscan-<os>-<arch>
#   5. Compute SHA-256 and update checksums.txt:
#        shasum -a 256 release/vexscan-<os>-<arch> >> scripts/lib/vexscan/checksums.txt
#      (Format: `<sha>  <asset-name>` per line. Replace existing entry on
#       bumps; add new entries when supporting a new platform.)
#   6. Verify both bootstrap paths against a clean SIGIL_STATE_DIR:
#        - default (downloads from release once it exists)
#        - SIGIL_VEXSCAN_FROM_SOURCE=1 (rebuilds from source)
#   7. Commit pin.sh + Cargo.lock + checksums.txt together.
#   8. After merge, tag a release `vexscan-<short_sha>` on the Sigil repo
#      with the binary artifacts attached. Until that release exists, the
#      bootstrap automatically falls back to the source build.

VEXSCAN_PIN_REPO="https://github.com/edimuj/vexscan"
VEXSCAN_PIN_COMMIT="7a23ee696d2b2a3598b964d1b206ccda78dd5540"
