#!/bin/sh
#
#  make-epub-fixtures.sh
#  Paperbound
#
#  Builds the EPUB test fixtures from the plain source files in
#  PaperboundTests/Fixtures/epub-src/:
#
#    Sample.epub     a small reflowable EPUB 3 (four chapters, nested nav TOC,
#                    an image, a footnote, a declared cover image)
#    Protected.epub  the same book with an Adobe ADEPT-style
#                    META-INF/encryption.xml, so DRM detection can be tested
#    FairPlay.epub   the same book with an Apple FairPlay-style
#                    META-INF/sinf.xml (Readium does not flag these itself)
#
#  The OCF container rules are what make this fiddly: `mimetype` must be the
#  first entry in the zip, stored uncompressed and without extra fields (zip
#  -X0), or strict readers reject the file. Everything else is deflated after.
#
#  Timestamps are pinned so rebuilding from unchanged sources gives the same
#  bytes, which keeps the fixtures from showing up as spurious changes.
#
#  Usage: Tools/make-epub-fixtures.sh   (from anywhere)
#

set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURES="$ROOT/PaperboundTests/Fixtures"
SRC="$FIXTURES/epub-src"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/paperbound-epub.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Copies the book sources into a staging folder with fixed timestamps.
stage() {
    dest="$1"
    mkdir -p "$dest"
    cp "$SRC/mimetype" "$dest/mimetype"
    cp -R "$SRC/META-INF" "$dest/META-INF"
    cp -R "$SRC/OEBPS" "$dest/OEBPS"
    find "$dest" -name '.DS_Store' -delete
    find "$dest" -exec touch -t 202610010000 {} +
}

# Zips a staged folder into an OCF container at $2.
pack() {
    staged="$1"
    output="$2"
    rm -f "$output"
    (
        cd "$staged"
        zip -X0 -q "$output" mimetype
        # Sorted so the entry order, and with it the bytes, are stable.
        find META-INF OEBPS -type f | LC_ALL=C sort | zip -X9 -q "$output" -@
    )
}

stage "$WORK/sample"
pack "$WORK/sample" "$FIXTURES/Sample.epub"

stage "$WORK/protected"
cp "$SRC/extras/encryption.xml" "$WORK/protected/META-INF/encryption.xml"
touch -t 202610010000 "$WORK/protected/META-INF/encryption.xml"
pack "$WORK/protected" "$FIXTURES/Protected.epub"

# The sinf.xml is written here rather than kept in epub-src/, so the test
# target's membership-exception list does not need another entry.
stage "$WORK/fairplay"
cat > "$WORK/fairplay/META-INF/sinf.xml" <<'SINF'
<?xml version="1.0" encoding="UTF-8"?>
<fairplay:sinf xmlns:fairplay="http://itunes.apple.com/ns/epub">
  <fairplay:sData>UGFwZXJib3VuZCB0ZXN0IGZpeHR1cmUsIG5vdCBhIHJlYWwga2V5Lg==</fairplay:sData>
</fairplay:sinf>
SINF
touch -t 202610010000 "$WORK/fairplay/META-INF/sinf.xml"
pack "$WORK/fairplay" "$FIXTURES/FairPlay.epub"

echo "Wrote $FIXTURES/Sample.epub"
echo "Wrote $FIXTURES/Protected.epub"
echo "Wrote $FIXTURES/FairPlay.epub"
