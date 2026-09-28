# Open JTalk runtime dictionary: notices

`KBJapaneseKit` reads Japanese morphology through an Open JTalk dictionary that it downloads
on first use. The dictionary is **not** redistributed in this repository and is **not** covered
by the Apache License 2.0 in `LICENSE`.

## What is downloaded

| | |
|---|---|
| Archive | `open_jtalk_dic_utf_8-1.11.tar.gz` |
| Release | Open JTalk v1.11.1, <https://github.com/r9y9/open_jtalk/releases/tag/v1.11.1> |
| URL | <https://github.com/r9y9/open_jtalk/releases/download/v1.11.1/open_jtalk_dic_utf_8-1.11.tar.gz> |
| SHA-256 | `fe6ba0e43542cef98339abdffd903e062008ea170b04e7e2a35da805902f382a` |
| Declared in | `Packages/KBJapaneseKit/Sources/KBJapaneseKit/OpenJTalkDictionary.swift` |

The bytes are pinned by that digest, so the notices below describe exactly one artefact and
cannot silently become notices for a different one.

## The archive's own COPYING is preserved

The archive carries a `COPYING` file holding the complete licence text, and that file is the
authoritative record. `OpenJTalkDictionary.extract(archive:into:)` streams every regular tar
entry to disk under its archived path; it skips only symlinks, device entries and paths that
attempt traversal, none of which the dictionary contains. `COPYING` is therefore written out
with the dictionary data and is present in the installed directory, next to `sys.dic`,
`matrix.bin`, `char.bin` and `unk.dic`.

Nothing in this package deletes, rewrites or filters it.

## Who holds the copyright

The dictionary is a three-part work, each part under a three-clause BSD licence:

1. **The Nara Institute of Science and Technology (NAIST)**, for the NAIST Japanese
   Dictionary the Open JTalk dictionary is built from.
2. **The UniDic Consortium**, for the UniDic material carried in it.
3. **The Nagoya Institute of Technology, Department of Computer Science, and the HTS Working
   Group**, for Open JTalk itself and for the packaging of the dictionary.

Read the exact wording, warranty disclaimers and non-endorsement clauses from the `COPYING`
file in the installed dictionary directory, or from the upstream release linked above. The
upstream release notes direct users to that file rather than restating it, and so does this
one: a paraphrase is not a licence.

The Open JTalk notice is reproduced verbatim in `Licenses/OpenJTalk-Engine-BSD.txt`, taken
from the engine sources vendored in the MisakiSwift fork this package depends on. The NAIST
and UniDic notices are not reproduced here because this repository vendors no copy of them to
quote from; take them from the downloaded `COPYING`.

## What a consuming app must do

If you ship an app built on `KBJapaneseKit`, you redistribute this dictionary to your users as
soon as it is downloaded onto their device. You must:

1. Reproduce the three BSD notices from the archive's `COPYING`, in full and without
   modification, in your documentation or About material. A link is not enough: the licence
   requires the notice in the materials that accompany the distribution.
2. Keep the non-endorsement clauses intact. None of NAIST, the UniDic Consortium, the Nagoya
   Institute of Technology or the HTS Working Group endorses your app, and you may not imply
   that they do.
3. Not remove the `COPYING` file from the installed dictionary directory.

`Packages/KBJapaneseKit/README.md` repeats this requirement where a reader of that package
will meet it.

## MeCab

The Open JTalk engine in the MisakiSwift fork also vendors MeCab, under a three-clause BSD
licence: Copyright (c) 2001-2008 Taku Kudo, Copyright (c) 2004-2008 Nippon Telegraph and
Telephone Corporation. Its full text is in `Sources/COpenJTalk/openjtalk/mecab/COPYING` in
that fork, and it must be preserved by the same rule that preserves the Open JTalk notice.
