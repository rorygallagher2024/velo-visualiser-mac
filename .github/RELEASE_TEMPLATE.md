# Release notes template

Copy the block below into `gh release create --notes-file`. Replace the
`What's new` section; leave `Install` as it is so every release carries the
same, correct instructions.

Keep `What's new` written for someone using the app, not reading the diff: say
what changed for them and, for a fix, what the broken behaviour looked like so
they can tell whether it was the thing biting them. Technical detail belongs in
the commit message.

---

A bug-fix release on top of [vPREVIOUS](https://github.com/rorygallagher2024/velo-visualiser-mac/releases/tag/vPREVIOUS).

## What's new

### Short headline for the change
What it does, or what was broken and how it showed up.

## Install

Velo is signed ad hoc rather than with a paid Apple Developer certificate, so a
browser download triggers a Gatekeeper warning. **Two of these three routes
avoid it entirely** — the warning comes from the `com.apple.quarantine` flag,
which is set by your browser, not by macOS.

**Terminal download — no warning:**

```bash
curl -L -o velo.zip https://github.com/rorygallagher2024/velo-visualiser-mac/releases/latest/download/velo-visualiser-mac.zip
ditto -x -k velo.zip /Applications
```

Use `ditto`, not `unzip` — plain `unzip` does not restore the bundle metadata
the archive stores, leaving the app's code signature invalid.

**Build from source — no warning:**

```bash
git clone --recursive https://github.com/rorygallagher2024/velo-visualiser-mac.git
cd velo-visualiser-mac && ./build.sh release
```

**Browser download — one warning, once.** Grab `velo-visualiser-mac.dmg` and
drag the app to Applications, then either open **System Settings > Privacy &
Security** and click **Open Anyway**, or clear the flag yourself:

```bash
xattr -d com.apple.quarantine "/Applications/Velo Visualiser.app"
```

That last command removes a macOS security check, so only run it on software you
trust — the full source is in this repository.

Requires macOS 26 or later on Apple silicon.
