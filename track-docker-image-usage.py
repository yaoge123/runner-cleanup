#!/usr/bin/env python3
"""
Docker image usage tracker.

Listens to Docker events and records the last-used time for each image.
Outputs a JSON file mapping image tags to their last observed usage time.

Usage:
    python3 track-docker-image-usage.py [--state FILE] [--interval SECS]

State file format:
    {"images": {"python:3.11": {"last_used": "2026-05-17T10:30:00+08:00", "last_event": "container:start", "usage_count": 42}, ...}}
"""

import argparse
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone, timedelta


def now_iso():
    return datetime.now().astimezone().isoformat()


def epoch_to_iso(epoch_seconds):
    return datetime.fromtimestamp(epoch_seconds, tz=timezone.utc).astimezone().isoformat()


def load_state(path):
    if os.path.exists(path):
        with open(path, "r") as f:
            return json.load(f)
    return {"images": {}}


def save_state(path, state):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f, indent=2, ensure_ascii=False)
    os.replace(tmp, path)


def build_digest_map():
    """Build a mapping from sha256 digest to list of image tags."""
    try:
        result = subprocess.run(
            ["docker", "images", "--no-trunc", "--format", "{{.ID}}\t{{.Repository}}:{{.Tag}}"],
            capture_output=True, text=True, timeout=10
        )
        digest_map = {}
        for line in result.stdout.strip().splitlines():
            if not line.strip():
                continue
            parts = line.split("\t", 1)
            if len(parts) != 2:
                continue
            digest, tag = parts
            digest_key = "sha256:" + digest
            if digest_key not in digest_map:
                digest_map[digest_key] = []
            digest_map[digest_key].append(tag)
        return digest_map
    except Exception as e:
        print(f"WARN: failed to build digest map: {e}", file=sys.stderr)
        return {}


def record_usage(state, tag, event_type, timestamp_iso):
    if tag not in state["images"]:
        state["images"][tag] = {
            "last_used": timestamp_iso,
            "last_event": event_type,
            "usage_count": 0,
        }
    entry = state["images"][tag]
    entry["last_used"] = timestamp_iso
    entry["last_event"] = event_type
    entry["usage_count"] = entry.get("usage_count", 0) + 1


def process_event(state, event_json, digest_map):
    try:
        event = json.loads(event_json)
    except json.JSONDecodeError:
        return False

    event_type = event.get("Type", "")
    action = event.get("Action", "")
    actor = event.get("Actor", {})
    attrs = actor.get("Attributes", {})
    event_time = event.get("time", 0)
    timestamp_iso = epoch_to_iso(event_time) if event_time else now_iso()

    changed = False

    if event_type == "image" and action == "pull":
        # image:pull event - Actor.ID contains the full tag
        image_id = actor.get("ID", "")
        if image_id:
            record_usage(state, image_id, "image:pull", timestamp_iso)
            changed = True
            print(f"  PULL {image_id} at {timestamp_iso}")

    elif event_type == "container" and action in ("create", "start"):
        # container event - attrs["image"] contains sha256 digest
        image_digest = attrs.get("image", "")
        if image_digest and image_digest.startswith("sha256:"):
            tags = digest_map.get(image_digest, [])
            if tags:
                for tag in tags:
                    record_usage(state, tag, f"container:{action}", timestamp_iso)
                    changed = True
                    print(f"  {action.upper()} {tag} (via {image_digest[:19]}...) at {timestamp_iso}")
            else:
                # Unknown digest, record as digest itself
                record_usage(state, image_digest, f"container:{action}", timestamp_iso)
                changed = True
                print(f"  {action.upper()} {image_digest[:19]}... (unknown tag) at {timestamp_iso}")

    return changed


def main():
    parser = argparse.ArgumentParser(description="Track Docker image usage via docker events")
    parser.add_argument("--state", default="/var/lib/runner-cleanup/image-usage.json",
                        help="Path to state file (default: /var/lib/runner-cleanup/image-usage.json)")
    parser.add_argument("--interval", type=int, default=300,
                        help="Seconds between digest map refresh and state save (default: 300)")
    parser.add_argument("--since", type=int, default=0,
                        help="Unix timestamp to start reading events from (0 = now, default: 0)")
    parser.add_argument("--once", action="store_true",
                        help="Run once: build digest map, record current state, then exit")
    parser.add_argument("--report", action="store_true",
                        help="Print a human-readable usage report and exit")
    parser.add_argument("--threshold-days", type=int, default=30,
                        help="Days since last use to mark as 'unused' in report (default: 30)")
    args = parser.parse_args()

    if args.report:
        if not os.path.exists(args.state):
            print(f"No state file found at {args.state}", file=sys.stderr)
            sys.exit(1)
        state = load_state(args.state)
        cutoff = datetime.now().astimezone() - timedelta(days=args.threshold_days)
        unused = []
        used_recently = []
        for tag, info in sorted(state["images"].items(), key=lambda x: x[1]["last_used"]):
            try:
                last_used = datetime.fromisoformat(info["last_used"])
            except (ValueError, TypeError):
                last_used = datetime.min.replace(tzinfo=timezone.utc)
            entry = (tag, info, last_used)
            if last_used < cutoff:
                unused.append(entry)
            else:
                used_recently.append(entry)

        print(f"=== Docker Image Usage Report ===")
        print(f"State file: {args.state}")
        print(f"Total images: {len(state['images'])}")
        print(f"Used in last {args.threshold_days} days: {len(used_recently)}")
        print(f"Unused for {args.threshold_days}+ days: {len(unused)}")
        print()
        if used_recently:
            print(f"--- Recently used (last {args.threshold_days} days) ---")
            for tag, info, last_used in sorted(used_recently, key=lambda x: x[2], reverse=True):
                print(f"  {tag}")
                print(f"    last_used={info['last_used']}, event={info['last_event']}, count={info['usage_count']}")
        print()
        if unused:
            print(f"--- Unused for {args.threshold_days}+ days (candidates for cleanup) ---")
            for tag, info, last_used in sorted(unused, key=lambda x: x[2]):
                print(f"  {tag}")
                print(f"    last_used={info['last_used']}, event={info['last_event']}, count={info['usage_count']}")
        return

    state_dir = os.path.dirname(args.state)
    if state_dir:
        os.makedirs(state_dir, exist_ok=True)

    state = load_state(args.state)

    if args.once:
        # One-shot mode: build digest map from current docker images and record existing containers
        digest_map = build_digest_map()
        # Record all currently running containers as "already in use"
        try:
            result = subprocess.run(
                ["docker", "ps", "--format", "{{.Image}}\t{{.ID}}\t{{.Names}}"],
                capture_output=True, text=True, timeout=10
            )
            now = now_iso()
            for line in result.stdout.strip().splitlines():
                if not line.strip():
                    continue
                parts = line.split("\t", 2)
                if len(parts) >= 1:
                    image_ref = parts[0]
                    record_usage(state, image_ref, "container:existing", now)
        except Exception as e:
            print(f"WARN: failed to list running containers: {e}", file=sys.stderr)

        # Also record all existing images with their creation time
        try:
            result = subprocess.run(
                ["docker", "images", "--format", "{{.Repository}}:{{.Tag}}\t{{.CreatedAt}}"],
                capture_output=True, text=True, timeout=10
            )
            for line in result.stdout.strip().splitlines():
                if not line.strip():
                    continue
                parts = line.split("\t", 1)
                if len(parts) == 2:
                    tag, created = parts
                    if tag not in state["images"]:
                        state["images"][tag] = {
                            "last_used": created,
                            "last_event": "image:existing",
                            "usage_count": 0,
                        }
        except Exception as e:
            print(f"WARN: failed to list existing images: {e}", file=sys.stderr)

        save_state(args.state, state)
        print(f"Recorded {len(state['images'])} images in {args.state}")
        return

    # Streaming mode: listen to docker events
    since_arg = str(args.since) if args.since > 0 else str(int(time.time()))
    cmd = [
        "docker", "events",
        "--since", since_arg,
        "--filter", "type=image",
        "--filter", "type=container",
        "--filter", "event=pull",
        "--filter", "event=create",
        "--filter", "event=start",
        "--format", "{{json .}}",
    ]

    print(f"Starting Docker image usage tracker")
    print(f"State file: {args.state}")
    print(f"Listening to events: {' '.join(cmd[2:])}")
    print(f"Refresh interval: {args.interval}s")

    digest_map = build_digest_map()
    last_refresh = time.time()
    last_save = time.time()

    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        for line in proc.stdout:
            line = line.strip()
            if not line:
                continue

            changed = process_event(state, line, digest_map)

            # Periodically refresh digest map and save state
            now = time.time()
            if now - last_refresh >= args.interval:
                digest_map = build_digest_map()
                last_refresh = now

            if changed and now - last_save >= 10:
                save_state(args.state, state)
                last_save = now

    except KeyboardInterrupt:
        print("\nShutting down...")
        if proc:
            proc.terminate()
    finally:
        save_state(args.state, state)
        print(f"Final state: {len(state['images'])} images tracked")


if __name__ == "__main__":
    main()
