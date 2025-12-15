#!/usr/bin/env python3
"""
Simple helper to replace the first occurrence of a string within a file.
"""

import argparse
from pathlib import Path


def replace_once(path: Path, needle: str, replacement: str) -> bool:
    content = path.read_text()
    if needle not in content:
        return False
    path.write_text(content.replace(needle, replacement, 1))
    return True


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Replace the first occurrence of NEEDLE with REPLACEMENT in FILE."
    )
    parser.add_argument("file", help="Path to the file to mutate")
    parser.add_argument("needle", help="String to search for")
    parser.add_argument("replacement", help="Replacement string")
    args = parser.parse_args()

    file_path = Path(args.file)
    if not file_path.exists():
        parser.error(f"file does not exist: {file_path}")

    replace_once(file_path, args.needle, args.replacement)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
