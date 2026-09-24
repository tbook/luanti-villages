# VoxeLibre villager extension proposal

`voxelibre-villager-extension.patch` is prepared against VoxeLibre master commit
`4492ce6` (September 2026). It adds small profession and activity registration
hooks used by the tavern keeper. Apply it to a compatible VoxeLibre checkout
with `git apply upstream/voxelibre-villager-extension.patch`, then run the game
with Villages enabled. The patch belongs in VoxeLibre, not in an installed game
directory; issue #35 tracks the upstream contribution and review.

Until VoxeLibre exposes these hooks, Villages continues loading its existing
features and logs that tavern service is disabled.
