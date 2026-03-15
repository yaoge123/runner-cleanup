#!/usr/bin/env bash

set -euo pipefail

KEEP_MAX_IMAGES=$1
DRY_RUN=${DRY_RUN:-1}
REPOSITORIES=$(docker images --format '{{.Repository}}' | sort -u)

echo "[$(date +'%Y-%m-%d %H:%M:%S')] Start cleaning up old images"
echo "[$(date +'%Y-%m-%d %H:%M:%S')] DRY_RUN=${DRY_RUN}"

for repo in $REPOSITORIES; do
    # `docker images` lists newest images first. Keep the first N unique IDs and
    # only consider the trailing older IDs for removal.
    IMAGE_IDS=$(docker images --format '{{.ID}}' --filter=reference="$repo" | awk 'NF && !seen[$0]++')

    IMAGE_COUNT=$(echo "$IMAGE_IDS" | wc -l)

    if [ "$IMAGE_COUNT" -gt "$KEEP_MAX_IMAGES" ]; then
        IMAGES_TO_REMOVE=$((IMAGE_COUNT - KEEP_MAX_IMAGES))
        IDS_TO_REMOVE=$(echo "$IMAGE_IDS" | tail -n "$IMAGES_TO_REMOVE")

        if [ "${DRY_RUN}" = "1" ]; then
            echo "[$(date +'%Y-%m-%d %H:%M:%S')] Would remove $IMAGES_TO_REMOVE old image(s) of repository: $repo"
            for id in $IDS_TO_REMOVE; do
                echo "[$(date +'%Y-%m-%d %H:%M:%S')] DRY_RUN=1 would run: docker rmi -f $id"
            done
        else
            echo "[$(date +'%Y-%m-%d %H:%M:%S')] Removing $IMAGES_TO_REMOVE old image(s) of repository: $repo"
            for id in $IDS_TO_REMOVE; do
                docker rmi -f "$id"
            done
            echo "[$(date +'%Y-%m-%d %H:%M:%S')] Removed $IMAGES_TO_REMOVE old image(s) of repository: $repo"
        fi
    fi
done

echo "[$(date +'%Y-%m-%d %H:%M:%S')] Finished cleaning up old images"
