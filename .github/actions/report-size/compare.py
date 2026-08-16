"""Format a size comparison against the last entry recorded on main."""
import argparse
import json
import os


def human(n):
    sign = "-" if n < 0 else ""
    n = float(abs(n))
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return f"{sign}{int(n)} {unit}" if unit == "B" else f"{sign}{n:.1f} {unit}"
        n /= 1024
    return f"{sign}{n:.1f} GB"  # unreachable, satisfies static analysis


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--history-file")
    parser.add_argument("--bytes", type=int, required=True)
    parser.add_argument("--label", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    prev_bytes = None
    if args.history_file and os.path.exists(args.history_file):
        try:
            with open(args.history_file) as f:
                history = json.load(f)
            if history:
                prev_bytes = history[-1]["bytes"]
        except (json.JSONDecodeError, KeyError, IndexError, TypeError):
            # TypeError covers valid JSON that isn't the list-of-entries shape
            # this file is supposed to hold (e.g. a stale or incompatible
            # cache) - degrade to "no recorded size" like any other malformed
            # history file instead of crashing the job.
            prev_bytes = None

    lines = [f"### {args.label} size", ""]
    if prev_bytes is not None:
        delta = args.bytes - prev_bytes
        pct = (delta / prev_bytes * 100) if prev_bytes else 0.0
        lines += [
            "| | |",
            "|---|---|",
            f"| Current | {human(args.bytes)} |",
            f"| main (last recorded) | {human(prev_bytes)} |",
            f"| Change | {'+' if delta >= 0 else ''}{human(delta)} ({pct:+.2f}%) |",
        ]
    else:
        lines += [
            "No recorded size on main yet — nothing to compare against.",
            "",
            "| | |",
            "|---|---|",
            f"| Current | {human(args.bytes)} |",
        ]

    text = "\n".join(lines) + "\n"
    with open(args.out, "w") as f:
        f.write(text)
    print(text)


if __name__ == "__main__":
    main()
