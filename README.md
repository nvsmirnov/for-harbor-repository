# for-harbor-repository

Auxiliary things for Harbor registry

`harbor-stats.sh`: gather statistics per docker registry repo and print them as prometheus metrics.
Note that sizes are highly inaccurate (no deduplication), but for my task it was enough to have object count per-repo.
