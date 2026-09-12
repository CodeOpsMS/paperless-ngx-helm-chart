#!/usr/bin/env python3
"""Reject mixed, incomplete or untrusted CI provenance before release acceptance."""
import argparse
import json
import re
from pathlib import Path

# Counts cover every supported matrix leg, not just a green workflow summary.
# Required test steps must also succeed (no skipped/continue-on-error bypass).
REQUIRED_JOBS = (
    ("Static / Helm ", 2, "Run chart unit tests"),
    ("Build immutable candidate", 1, "Upload candidate chart"),
    ("Required install / Helm ", 1, "Run fresh-install E2E"),
    ("Full install / Helm ", 6, "Install immutable candidate"),
    ("Upgrade / ", 4, "Run application upgrade E2E"),
    ("Monitoring / ", 1, "Test ServiceMonitor, Flower scrape, alert rules and traffic isolation"),
    ("GitHub Kubernetes acceptance / ", 1, "Test both baselines with monitoring and enforced NetworkPolicy"),
)


def verify_jobs(pages, source_sha, run_id):
    if not isinstance(pages, list) or not pages:
        raise ValueError("Missing CI job pages")
    jobs = [job for page in pages for job in page["jobs"]]
    for prefix, count, step_name in REQUIRED_JOBS:
        matches = [job for job in jobs if job.get("name", "").startswith(prefix)]
        if len(matches) != count or len({job["name"] for job in matches}) != count:
            raise ValueError(f"Missing, duplicate or unexpected CI jobs: {prefix}")
        for job in matches:
            expected = dict(run_id=int(run_id), head_sha=source_sha,
                            status="completed", conclusion="success")
            if any(job.get(key) != value for key, value in expected.items()):
                raise ValueError(f"CI job not successful for this source: {prefix}")
            steps = [step for step in job.get("steps", []) if step.get("name") == step_name]
            if (len(steps) != 1 or steps[0].get("status") != "completed"
                    or steps[0].get("conclusion") != "success"):
                raise ValueError(f"Required CI test did not succeed: {step_name}")


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
    parser.add_argument("--jobs", type=Path, required=True,
                        help="Paginated --slurp jobs response with filter=latest")
    args = parser.parse_args()
    verify(json.loads(args.metadata.read_text()), args.repository, args.source_sha, args.run_id, args.attempt)
    verify_jobs(json.loads(args.jobs.read_text()), args.source_sha, args.run_id)
    print("Verified successful main CI provenance and every required test job")
