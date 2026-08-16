"""Append the current size to the history file recorded on main."""
import argparse
import datetime
import json
import os


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--history-file", required=True)
    parser.add_argument("--bytes", type=int, required=True)
    parser.add_argument("--sha", required=True)
    args = parser.parse_args()

    history = []
    if os.path.exists(args.history_file):
        try:
            with open(args.history_file) as f:
                history = json.load(f)
        except json.JSONDecodeError:
            history = []

    history.append(
        {
            "sha": args.sha,
            "date": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "bytes": args.bytes,
        }
    )

    # Keep the file small - the comparison only ever reads the last entry.
    with open(args.history_file, "w") as f:
        json.dump(history[-50:], f)


if __name__ == "__main__":
    main()
