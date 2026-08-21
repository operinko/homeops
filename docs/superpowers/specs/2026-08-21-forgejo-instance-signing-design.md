# Forgejo Instance Commit Signing (SSH) — Design

**Date:** 2026-08-21
**Status:** Approved

## Context

The forge LXC (`192.168.7.30`, Forgejo 16.0.2) authors git commits on its own
behalf: repo-initialisation commits, web-UI and API file edits (including the
n8n workflows that push via the contents API), wiki edits, and PR merges. None
of them are signed, so nothing distinguishes a commit Forgejo made from one
anybody with a token could have fabricated.

Forgejo supports signing those commits with an instance key. As of Forgejo 15
that key may be an SSH key rather than OpenPGP, which suits this setup — the
whole forge already speaks SSH and there is no GPG tooling on the LXC.

Reference: <https://forgejo.org/docs/v15.0/admin/advanced/signing/>

### Prerequisites (verified on the LXC)

| Requirement | Needed | Present |
|---|---|---|
| git | ≥ 2.34.0 | 2.47.3 |
| ssh-keygen | ≥ 8.2p1 | OpenSSH 10.0p2 |

### Constraint that shapes the design

Forgejo documents that **instance signing key rotation is not currently
possible**. Once history is signed with this key, replacing it orphans every
prior signature. The key must therefore outlive the LXC.

## Decisions

- **Key storage: `forge/secrets.sops.yaml`.** A dedicated ed25519 keypair,
  no passphrase, generated once. Given rotation is impossible, the key has to
  survive an LXC rebuild, and sops is already the module's secret store.
- **Only the private half is stored.** The public half is derived on the host
  with `ssh-keygen -y`. It is not secret and is fully determined by the private
  key; keeping one source of truth means the halves cannot drift.
- **Sign everything Forgejo authors** — `INITIAL_COMMIT`, `CRUD_ACTIONS`,
  `WIKI` and `MERGES` all `always`. Simplest rule to reason about: if Forgejo
  wrote the commit, it is signed. Commits pushed over git by a human or a CI
  runner are untouched and carry their own signature or none.
- **Signing identity reuses the mailer address**, `Forgejo
  <forgejo@vaderrp.com>`. It is not a registered Forgejo account, so these
  commits present as an unattributed instance identity — correct for a machine
  signer.
- **`DEFAULT_TRUST_MODEL` stays at its `collaborator` default.**
  Instance-signed commits verify against `SIGNING_KEY` regardless of it.

## Design

### Key placement

Both files live in `/etc/forgejo/`, alongside `app.ini` (the directory is
already `root:git 0770`):

| Path | Owner | Mode |
|---|---|---|
| `/etc/forgejo/signing.key` | `git:git` | `0600` |
| `/etc/forgejo/signing.key.pub` | `root:git` | `0644` |

Forgejo's convention is that `SIGNING_KEY` names the `.pub` path and expects
the private key at the same path minus the suffix, which this layout satisfies
directly.

### `forge/config/app.ini.j2`

```ini
[repository.signing]
FORMAT = ssh
SIGNING_KEY = /etc/forgejo/signing.key.pub
SIGNING_NAME = Forgejo
SIGNING_EMAIL = forgejo@vaderrp.com
INITIAL_COMMIT = always
CRUD_ACTIONS = always
WIKI = always
MERGES = always
```

Note the format selector is `FORMAT`, not `SIGNING_FORMAT`.

### `forge/mod.just`

`apply-forgejo` gains one further sops → minijinja → ssh render, mirroring the
existing `app.ini` line, writing the private key into the `0700` staging
directory under `umask 077`. The existing trailing `rm -rf` already wipes it.

### `forge/apply-forgejo.sh`

A block that installs the staged private key and, when it changes, regenerates
the `.pub` beside it and sets `RESTART_FORGEJO=1`. It sits before the existing
restart so a single restart covers both `app.ini` and the key.

## Verification

1. Edit a file through the web UI in a throwaway repo.
2. On the LXC, `git -C <repo path> log --show-signature -1` reports a good SSH
   signature.
3. The commit carries the "Verified" badge in the web UI.
4. Confirm empirically what `MERGES = always` does against
   `DEFAULT_MERGE_STYLE = rebase`, which produces no merge commit. The
   expectation is that the rebased commits are signed; this is not asserted
   until observed.

## Out of scope

- Verification of *pushed* commits (users registering SSH keys as verification
  keys under their account).
- Any change to runner or mirror behaviour.
