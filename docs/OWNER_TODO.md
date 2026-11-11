# Owner TODO

Things only the founder can do. Kept in priority order. The team asks for these
one at a time, and only when they actually block progress.

Status key: **blocking** — work is stopped on it now. **soon** — will block
within the current or next phase. **later** — not urgent, recorded so it is not
forgotten.

---

## 1. Rotate the GitHub token that was shared in chat — blocking

A classic personal access token (`ghp_...`) was pasted into the session. Treat
it as compromised regardless of what it could reach:

1. Revoke it at **GitHub → Settings → Developer settings → Personal access
   tokens**.
2. Check **Settings → Sessions** and the repository's audit log for anything
   you do not recognise.

The token was never written to any file in this repository and was not used to
authenticate anything. It could not be used even deliberately: this session's
network layer injects its own GitHub credentials for `github.com`, so a
user-supplied token is overridden before a request leaves the container. Rotate
it anyway — a secret that has appeared in a transcript is spent.

Nothing in this project needs a personal access token. Repository access comes
from the GitHub App in item 2.

## 2. Grant repository write access to the Claude GitHub App — blocking

Right now the session can read `u6765323803-cell/pledrin` but cannot push.
Every commit made so far exists only in this container, which is reclaimed when
the session ends, and no CI has ever run.

1. Go to **https://claude.ai/connect-github**.
2. Connect or reconnect the GitHub account that owns the repository.
3. Install the Claude GitHub App **on `u6765323803-cell/pledrin`** with write
   access (granting it to just this repository is enough).
4. Tell the team when it is done. A session's repositories are fixed when it
   starts, so a **new session** may be needed for the change to take effect.

Until this is done the team cannot push branches, open pull requests, or have
GitHub Actions run — which means the whole review-and-merge workflow and every
quality gate is inert.

## 3. Approve the Phase 0 specification — done 2026-11-11

Approved. Both decisions that blocked Phase 1 are answered and recorded in
`docs/OPEN_DECISIONS.md`: `LiquidityLock` gets a permissionless compound-only
function, and the v4 price-reset fallback is committed in advance.

Items 1 and 2 above are also done — the GitHub App has write access, `main`
and the Phase 0 branch are pushed, and CI has run green.

## 4. Decide the protocol treasury address — soon

The protocol fee share needs a destination, fixed at deploy. Decide:

- Which address receives protocol fees. Use an address you control from
  hardware, not a hot wallet.
- Whether it is a plain address or a multisig. A multisig is strongly
  recommended, and it costs nothing to decide now and everything to change
  later, since the address is immutable in the deployed contracts.

Needed before the testnet deploy script is finalised.

## 5. Fund a testnet deploy wallet — soon

Needed for the Phase 3 testnet deploy. Robinhood Chain testnet is chain ID
46630 and pays gas in ETH.

- Decide which address signs testnet deploys. It should not be the address that
  will later sign mainnet deploys.
- Fund it with testnet ETH. The team has not yet identified an official faucet
  for chain 46630; if you know the route, say so, otherwise the team will find
  and verify one before this becomes blocking.

Private keys stay with you. The team produces scripts and tells you exactly what
to run; it never holds a key.

## 6. RPC provider account — soon

The public endpoints in `docs/CHAIN_FACTS.md` are fine for development, but the
indexer backfills aggressively and will hit rate limits. Decide whether to run
on public endpoints initially or open an account with a provider offering
Robinhood Chain. Needed before the indexer runs continuously, not before it is
written.

## 7. Domain and trademark — later

- Register the domain. Decide the production hostname so the frontend and any
  wallet deep links can be configured once rather than twice.
- Check whether "Pledrin" is clear to use as a mark in your jurisdiction, and
  file if you want it. Worth starting early because it is slow and independent
  of engineering.

## 8. External audit — later, and a hard gate

**Mainnet deploy happens only after an external audit.** Until then, testnet
only. No exceptions, including for a "small" or "friends-only" launch, because
the contracts hold user funds from the first launch.

Start conversations with audit firms while Phase 1 is in progress — the good
ones book out months ahead. Budget for a re-review after fixes, not just the
first pass.

## 9. Sign the mainnet deploy — later

Blocked on item 8. The team produces the deploy script, the exact command, and a
deployment checklist; you review and sign from your own wallet. No one else
signs, and the team never has access to the signing key.

## 10. Decide whether the "Pledged" badge distinguishes bond size — soon

`bondWei` is chosen by the creator at launch, and the contracts treat any
non-zero bond the same way: the launch is pledged, the creator's fee share
rises, and the bond is forfeitable. A bond of 0.01 ETH therefore earns the same
badge as a bond of 10 ETH.

That is a product decision rather than a contract defect, and it is the weakest
point in the protocol's main claim. The bond is what makes "skin in the game"
literal; a badge that does not distinguish size lets a creator buy the signal
for almost nothing, and once buyers notice, the badge stops carrying
information for the creators who posted a real bond.

Options, none of which needs a contract change except the last:

- Show the bond amount next to the badge and let buyers judge. Costs nothing
  and keeps the contracts as they are, but puts the work on the buyer.
- Show the bond relative to something — the ETH raised so far, or the creator's
  own first buy — so the number means something without the buyer doing
  arithmetic.
- Band the badge in the interface only, by bond size. Still no contract change.
- Set a minimum bond for the badge in the contracts. This one is a contract
  change and a new deploy parameter, so it has to be decided before the
  contracts are reviewed and frozen rather than after.

My recommendation is the second option with the fourth held in reserve: display
the bond relative to the ETH raised, and keep a minimum out of the contracts
until there is real usage to set it from. A minimum chosen now would be a guess
baked into an immutable parameter.

Needed before the web application designs the launch card, and before the
testnet deploy parameters are fixed if you want the fourth option.
