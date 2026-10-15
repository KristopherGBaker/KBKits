#!/usr/bin/env bash
# Regenerates KBAnkiKit's `unicase` fold table from Rust's unicase crate, at the exact
# version Anki pins (`unicase = "=2.6.0"`).
#
# Anki's `unicase` SQLite collation is `UniCase::unicode` order: map each scalar through the
# crate's own fold table (`src/unicode/map.rs`, generated 2019-08-31), flatten what the
# crate's `Fold` iterator yields, compare the scalar sequences. That table is private to the
# crate, so this builds a throwaway Cargo project in a temporary directory that depends on
# the crate, copies the crate's `src/unicode/mod.rs` and `map.rs` into itself, and dumps
# every scalar whose fold is not itself. From that one dump it writes:
#
#   Packages/KBAnkiKit/Sources/KBAnkiKit/UnicaseFold.swift                 the table
#   Packages/KBAnkiKit/Tests/KBAnkiKitTests/Resources/unicase-2.6.0-folds.tsv  the oracle
#
# The dump keeps the order the crate's iterator YIELDS, which is not the table's for a
# three-scalar fold: `Fold::Three(a, b, c)` yields `c`, then `a`, then `b`. U+FB03 dumps as
# `69 66 66`, so the crate holds "ﬃ" equal to "iff" and not to "ffi". That is kept on
# purpose: the index order in a collection Anki wrote follows it.
#
# Usage:
#   Tools/generate-unicase-fold.sh          write both files
#   Tools/generate-unicase-fold.sh --check  render into a temporary directory, byte-compare
#                                           with the worktree, write nothing; exit 0 only
#                                           when both files match
#
# Needs `cargo`. The crate is taken from the local Cargo registry when it is there, and
# fetched otherwise. Nothing is built inside the repository.
set -euo pipefail

readonly crate_version="2.6.0"
readonly swift_path="Packages/KBAnkiKit/Sources/KBAnkiKit/UnicaseFold.swift"
readonly tsv_path="Packages/KBAnkiKit/Tests/KBAnkiKitTests/Resources/unicase-${crate_version}-folds.tsv"

mode=write
case "${1-}" in
    "") ;;
    --check) mode=check ;;
    *) echo "usage: $0 [--check]" >&2; exit 2 ;;
esac
if [ "$#" -gt 1 ]; then
    echo "usage: $0 [--check]" >&2
    exit 2
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/unicase-fold.XXXXXX")"
trap 'rm -rf "$work"' EXIT
project="$work/dump"
rendered="$work/rendered"
mkdir -p "$project/src/unicode" "$rendered"

export LC_ALL=C
export CARGO_TARGET_DIR="$project/target"

# Edition 2015 is the crate's own, so its copied modules resolve exactly as they do there.
# The empty [workspace] keeps Cargo from adopting any enclosing workspace.
cat > "$project/Cargo.toml" <<EOF
[package]
name = "unicase-fold-dump"
version = "0.0.0"
edition = "2015"
publish = false

[dependencies]
unicase = "=${crate_version}"

[workspace]
EOF

cat > "$project/src/main.rs" <<'EOF'
// The copied crate modules carry cfgs and items this binary never uses.
#![allow(warnings)]

extern crate core;
extern crate unicase;

mod unicode;

use std::char;
use std::io::{self, BufWriter, Write};
use unicase::UniCase;

fn hex(scalars: &[char]) -> String {
    scalars.iter().map(|c| format!("{:x}", *c as u32)).collect::<Vec<_>>().join(" ")
}

fn main() {
    // Cross-checks against the REAL crate, so a dump from a mis-copied table cannot pass.
    assert!(UniCase::unicode("\u{13A0}") < UniCase::unicode("\u{A000}"), "Cherokee before Yi");
    assert!(UniCase::unicode("\u{DF}") == UniCase::unicode("ss"), "sharp s folds to ss");
    assert!(UniCase::unicode("\u{FB03}") == UniCase::unicode("iff"), "ffi ligature yields iff");
    assert!(UniCase::unicode("\u{FB03}") != UniCase::unicode("ffi"), "ffi ligature is not ffi");

    let stdout = io::stdout();
    let mut out = BufWriter::new(stdout.lock());
    for value in 0..0x110000u32 {
        let scalar = match char::from_u32(value) {
            Some(scalar) => scalar,
            None => continue,
        };
        let fold = unicode::fold_of(scalar);
        if fold.len() == 1 && fold[0] == scalar {
            continue;
        }
        // The real crate must hold the scalar equal to the fold the copy reports.
        let original = scalar.to_string();
        let folded: String = fold.iter().collect();
        assert!(UniCase::unicode(&original[..]) == UniCase::unicode(&folded[..]),
                "U+{:04X}: the crate disagrees with the copied table", value);
        writeln!(out, "{:x}\t{}", value, hex(&fold)).unwrap();
    }
}
EOF

# Resolving offline first: the crate is normally in the local registry already, and a check
# should not need the network. Falls back to letting Cargo fetch it. Either way the crate is
# then local, so the build below runs offline.
metadata="$(cargo metadata --format-version 1 --manifest-path "$project/Cargo.toml" --offline \
        2>"$work/cargo-offline.log" \
    || cargo metadata --format-version 1 --manifest-path "$project/Cargo.toml")"
crate_manifest="$(printf '%s' "$metadata" \
    | grep -o "\"manifest_path\":\"[^\"]*/unicase-${crate_version}/Cargo.toml\"" \
    | head -n 1 \
    | sed -e 's/^"manifest_path":"//' -e 's/"$//')"
if [ -z "$crate_manifest" ]; then
    echo "error: Cargo did not resolve unicase ${crate_version}" >&2
    exit 1
fi
crate_dir="$(dirname "$crate_manifest")"

cp "$crate_dir/src/unicode/mod.rs" "$crate_dir/src/unicode/map.rs" "$project/src/unicode/"
chmod u+w "$project/src/unicode/mod.rs" "$project/src/unicode/map.rs"
cat >> "$project/src/unicode/mod.rs" <<'EOF'

/// Appended by Tools/generate-unicase-fold.sh: the scalars the crate's `Fold` iterator
/// yields for `c`, in that order.
pub fn fold_of(c: char) -> Vec<char> {
    lookup(c).collect()
}
EOF

tsv="$rendered/$(basename "$tsv_path")"
cargo run --release --quiet --offline --manifest-path "$project/Cargo.toml" > "$tsv"
if [ ! -s "$tsv" ]; then
    echo "error: the dump is empty" >&2
    exit 1
fi

# The Swift table: sorted parallel arrays and a binary search, which compile quickly where a
# dictionary literal of this size does not. The TSV is in ascending scalar order because the
# dump walks the scalars in order.
awk -F '\t' -v version="$crate_version" '
    function emit(name, type, values, count, doc,    i, line) {
        printf "%s", doc
        printf "    private static let %s: [%s] = [\n", name, type
        for (i = 1; i <= count; i++) {
            if ((i - 1) % 8 == 0) line = "       "
            line = line " " values[i] (i < count ? "," : "")
            if (i % 8 == 0 || i == count) print line
        }
        print "    ]"
    }
    {
        keys[NR] = "0x" toupper($1)
        count = split($2, fold, " ")
        if (count == 3) threes++
        starts[NR] = total + 0
        for (j = 1; j <= count; j++) scalars[++total] = "0x" toupper(fold[j])
    }
    END {
        starts[NR + 1] = total + 0
        print "// Generated by Tools/generate-unicase-fold.sh from Rust'\''s unicase " version ", the version"
        print "// Anki pins: the crate'\''s src/unicode/map.rs (generated 2019-08-31), read through the"
        print "// crate'\''s own `Fold` iterator. Do not edit; rerun the script."
        print "//"
        printf "// %d scalars fold to something other than themselves (%d of them to three scalars).\n", NR, threes
        print "// Every other scalar folds to itself."
        print ""
        print "/// Rust unicase " version "'\''s case fold, scalar by scalar: what Anki'\''s `unicase` collation"
        print "/// compares."
        print "enum UnicaseFold {"
        print "    /// The scalar values `scalar` folds to, in the order the crate'\''s `Fold` iterator yields"
        print "    /// them."
        print "    ///"
        print "    /// That is not always the order Unicode gives: `Fold::Three(a, b, c)` yields `c`, then"
        print "    /// `a`, then `b`, so U+FB03 \"ﬃ\" folds to \"iff\" and not to \"ffi\". It is kept on purpose,"
        print "    /// because the index order in a collection Anki wrote follows it."
        print "    static func fold(_ scalar: Unicode.Scalar) -> [UInt32] {"
        print "        let value = scalar.value"
        print "        var low = 0"
        print "        var high = keys.count"
        print "        while low < high {"
        print "            let middle = (low + high) / 2"
        print "            if keys[middle] < value {"
        print "                low = middle + 1"
        print "            } else {"
        print "                high = middle"
        print "            }"
        print "        }"
        print "        guard low < keys.count, keys[low] == value else { return [value] }"
        print "        return Array(scalars[starts[low]..<starts[low + 1]])"
        print "    }"
        print ""
        emit("keys", "UInt32", keys, NR, "    /// Every scalar whose fold is not itself, ascending.\n")
        print ""
        for (i = 1; i <= NR + 1; i++) startText[i] = starts[i]
        emit("starts", "Int", startText, NR + 1, \
            "    /// `keys[i]` folds to `scalars[starts[i]..<starts[i + 1]]`; one more entry than `keys`.\n")
        print ""
        emit("scalars", "UInt32", scalars, total, "    /// Every fold, concatenated in key order.\n")
        print "}"
    }
' "$tsv" > "$rendered/$(basename "$swift_path")"

if [ "$mode" = check ]; then
    status=0
    for path in "$swift_path" "$tsv_path"; do
        if ! cmp -s "$rendered/$(basename "$path")" "$root/$path"; then
            echo "differs: $path" >&2
            status=1
        fi
    done
    if [ "$status" -eq 0 ]; then
        echo "unicase ${crate_version} fold: both files match"
    fi
    exit "$status"
fi

mkdir -p "$root/$(dirname "$tsv_path")"
cp "$rendered/$(basename "$swift_path")" "$root/$swift_path"
cp "$tsv" "$root/$tsv_path"
echo "wrote $swift_path and $tsv_path ($(wc -l < "$tsv" | tr -d ' ') folds)"
