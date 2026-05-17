#!/usr/bin/env python3
"""
Docker image usage tracker.

Listens to Docker container:start events from GitLab Runner managed containers
and records per-image-digest usage statistics to a JSON state file.

Usage:
    python3 track-docker-image-usage.py [--state FILE]

State file: /var/lib/runner-cleanup/image-usage.json
"""

import argparse
import json
import os
import subprocess
import sys
import time
from urllib.parse import urlparse


def load_state(path):
    if os.path.exists(path):
        with open(path, "r") as f:
            return json.load(f)
    return {}


def save_state(path, state):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f, indent=2, ensure_ascii=False)
    os.replace(tmp, path)


def parse_project_from_url(url):
    """Extract project path from GitLab job URL."""
    if not url:
        return ""
    # https://git.example.com/org/project/-/jobs/12345
    try:
        parsed = urlparse(url)
        path = parsed.path.strip("/")
        # Remove /-/jobs/NNN suffix
        idx = path.find("/-/jobs/")
        if idx > 0:
            path = path[:idx]
        return path
    except Exception:
        return ""


def main():
    parser = argparse.ArgumentParser(description="Track Docker image usage via docker events")
    parser.add_argument("--state", default="/var/lib/runner-cleanup/image-usage.json",
                        help="Path to state file")
    args = parser.parse_args()

    state_dir = os.path.dirname(args.state)
    if state_dir:
        os.makedirs(state_dir, exist_ok=True)

    state = load_state(args.state)
    print(f"Loaded {len(state)} image records from {args.state}")

    cmd = [
        "docker", "events",
        "--filter", "type=container",
        "--filter", "event=start",
        "--filter", "label=com.gitlab.gitlab-runner.managed=true",
        "--format", "{{json .}}",
    ]

    print(f"Listening to docker events: {' '.join(cmd[2:])}")

    last_save = 0
    dirty = False

    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        for line in proc.stdout:
            line = line.strip()
            if not line:
                continue

            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue

            actor = event.get("Actor", {})
            attrs = actor.get("Attributes", {})
            digest = attrs.get("image", "")
            if not digest or not digest.startswith("sha256:"):
                continue

            timestamp = event.get("time", 0)
            if not timestamp:
                continue

            job_id = attrs.get("com.gitlab.gitlab-runner.job.id", "")
            job_url = attrs.get("com.gitlab.gitlab-runner.job.url", "")
            project = parse_project_from_url(job_url)

            # Update state (dedup by digest)
            if digest not in state:
                state[digest] = {
                    "last_used": timestamp,
                    "first_seen": timestamp,
                    "usage_count": 0,
                    "last_job_id": "",
                    "last_project": "",
                }

            entry = state[digest]
            entry["last_used"] = timestamp
            entry["usage_count"] = entry.get("usage_count", 0) + 1
            if job_id:
                entry["last_job_id"] = job_id
            if project:
                entry["last_project"] = project

            dirty = True

            # Throttle saves: write at most once per 10 seconds
            now = time.time()
            if dirty and now - last_save >= 10:
                save_state(args.state, state)
                last_save = now
                dirty = False

    except KeyboardInterrupt:
        print("\nShutting down...")
        if proc:
            proc.terminate()
    finally:
        if dirty:
            save_state(args.state, state)
        print(f"Final state: {len(state)} image records saved")


if __name__ == "__main__":
    main()
