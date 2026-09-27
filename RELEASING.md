# Releasing plimsoll

Nothing here is automated. CI only tests; it does not tag, publish or touch
the tap. A release is four manual steps, and skipping one leaves a visible gap:
no GitHub Release means `/releases/latest` stays on the old version, and no tap
bump means `brew upgrade` never sees the fix.

The version exists only as the git tag. No file in this repo carries it.

## 1. Tag main

After the PR is squash-merged and main is pulled:

```sh
git tag -a vX.Y.Z -m vX.Y.Z
git push origin vX.Y.Z
```

## 2. Publish the GitHub Release

Pushing a tag does not create a Release. Create it by hand:

```sh
gh release create vX.Y.Z --verify-tag --latest \
  --title "vX.Y.Z — <what changed, as an outcome>" \
  --notes-file notes.md
```

Notes are a bullet list. Each bullet opens with one bold sentence saying what
the user now sees, followed by the cause and the fix in plain words. See
earlier releases for the tone.

## 3. Bump the tap

The formula is `Formula/plimsoll.rb` in
[donco-labs/homebrew-tap](https://github.com/donco-labs/homebrew-tap). It
downloads the tag's source tarball, so update the `url` and its `sha256`:

```sh
TAP=$(brew --repo donco-labs/tap)       # or a clone of homebrew-tap
git -C "$TAP" pull --ff-only
curl -fsSL https://github.com/donco-labs/plimsoll/archive/refs/tags/vX.Y.Z.tar.gz \
  | shasum -a 256                        # the new sha256
# edit url + sha256 in $TAP/Formula/plimsoll.rb
git -C "$TAP" commit -am "plimsoll X.Y.Z"
git -C "$TAP" push origin main
```

## 4. Reinstall and check

```sh
brew update
brew reinstall donco-labs/tap/plimsoll
brew info plimsoll | head -1              # stable X.Y.Z
make plugin-status                        # menu bar runs the Homebrew copy
```

If SwiftBar should show the release rather than a checkout, run
`make plugin-brew`.
