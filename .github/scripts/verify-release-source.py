#!/usr/bin/env python3
"""Reject mixed, stale or untrusted CI provenance before cluster access."""
import argparse
import json
import re
from pathlib import Path


def verify(run, repository, source_sha, run_id, attempt):
    if not re.fullmatch(r"[0-9a-f]{40}", source_sha):
        raise ValueError("Invalid source commit")
    expected = {
        "id": int(run_id), "run_attempt": int(attempt), "head_sha": source_sha,
        "head_branch": "main", "event": "push", "status": "completed",
        "conclusion": "success", "path": ".github/workflows/helm-ci.yml",
    }
    if any(run.get(key) != value for key, value in expected.items()):
        raise ValueError("CI provenance does not match the successful main push")
    for key in ("repository", "head_repository"):
        if run.get(key, {}).get("full_name") != repository:
            raise ValueError("CI repository mismatch")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("metadata", type=Path)
    parser.add_argument("repository")
    parser.add_argument("source_sha")
    parser.add_argument("run_id", type=int)
    parser.add_argument("attempt", type=int)
    args = parser.parse_args()
    verify(json.loads(args.metadata.read_text()), args.repository, args.source_sha, args.run_id, args.attempt)
    print("Verified successful main CI provenance")
