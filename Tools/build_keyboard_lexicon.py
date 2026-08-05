#!/usr/bin/env python3
"""Build the memory-mapped nine-key lexicon bundled by the keyboard target."""

from __future__ import annotations

import argparse
import struct
from pathlib import Path

from pypinyin import Style, lazy_pinyin


MAGIC = b"Q9LX"
HEADER_SIZE = 12
LETTER_TO_DIGIT = str.maketrans(
    {
        **dict.fromkeys("abc", "2"),
        **dict.fromkeys("def", "3"),
        **dict.fromkeys("ghi", "4"),
        **dict.fromkeys("jkl", "5"),
        **dict.fromkeys("mno", "6"),
        **dict.fromkeys("pqrs", "7"),
        **dict.fromkeys("tuv", "8"),
        **dict.fromkeys("wxyz", "9"),
    }
)


def is_hanzi_word(word: str) -> bool:
    return bool(word) and all("\u3400" <= char <= "\u9fff" for char in word)


def digit_code(word: str) -> str | None:
    syllables = lazy_pinyin(
        word,
        style=Style.NORMAL,
        strict=False,
        errors=lambda _: [],
    )
    letters = "".join(syllables).lower().replace("ü", "v")
    if not letters or any(not ("a" <= char <= "z") for char in letters):
        return None
    return letters.translate(LETTER_TO_DIGIT)


def load_entries(source: Path, limit: int) -> list[tuple[str, str, int]]:
    ranked: list[tuple[int, str]] = []
    with source.open(encoding="utf-8") as handle:
        for line in handle:
            pieces = line.rstrip().split()
            if len(pieces) < 2:
                continue
            word = pieces[0]
            try:
                frequency = int(pieces[1])
            except ValueError:
                continue
            if len(word) <= 6 and is_hanzi_word(word):
                ranked.append((frequency, word))

    # Retain common entries before paying the pinyin conversion cost.
    ranked.sort(reverse=True)
    entries: dict[tuple[str, str], int] = {}
    for frequency, word in ranked:
        code = digit_code(word)
        if code:
            entries[(code, word)] = max(frequency, entries.get((code, word), 0))
        if len(entries) >= limit:
            break

    return sorted((code, word, frequency) for (code, word), frequency in entries.items())


def build(source: Path, destination: Path, limit: int) -> None:
    entries = load_entries(source, limit)
    records: list[bytes] = []
    for code, word, frequency in entries:
        code_bytes = code.encode("ascii")
        word_bytes = word.encode("utf-8")
        records.append(
            struct.pack("<BBI", len(code_bytes), len(word_bytes), min(frequency, 0xFFFFFFFF))
            + code_bytes
            + word_bytes
        )

    offsets_size = (len(records) + 1) * 4
    first_record = HEADER_SIZE + offsets_size
    offsets = [first_record]
    for record in records:
        offsets.append(offsets[-1] + len(record))

    destination.parent.mkdir(parents=True, exist_ok=True)
    with destination.open("wb") as output:
        output.write(MAGIC)
        output.write(struct.pack("<HHI", 1, 0, len(records)))
        output.write(struct.pack(f"<{len(offsets)}I", *offsets))
        output.writelines(records)

    print(f"wrote {len(records):,} entries to {destination} ({destination.stat().st_size:,} bytes)")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path, help="jieba-compatible dict.txt")
    parser.add_argument("destination", type=Path)
    parser.add_argument("--limit", type=int, default=50_000)
    args = parser.parse_args()
    build(args.source, args.destination, args.limit)


if __name__ == "__main__":
    main()
