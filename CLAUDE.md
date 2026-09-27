# plimsoll

- Changes go through a branch and PR, squash-merged after CI passes.
- To release or "update the tap", follow [RELEASING.md](RELEASING.md) — all
  four steps, including the GitHub Release, which pushing a tag does not create.
- The SwiftBar plugin runs in the C locale: no `$'\uXXXX'` escapes in zsh;
  write non-ASCII as its UTF-8 bytes or literally.
