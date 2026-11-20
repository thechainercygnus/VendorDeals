# CLAUDE.md

Instructions for AI coding agents working in this repo.

## What this is

A WoW: Forever addon (Lua 5.1, interface 16001) that lists Auction House buyouts below
the full stack's vendor sell price, sorted by profit. It reads Auctionator's replicate
scan when Auctionator is loaded (`## OptionalDeps: Auctionator`) and otherwise runs its
own scan. All code is in `VendorDeals/VendorDeals.lua`.

## Commands

No build or automated tests. To try a change in game:

```
..\Install-DevelopmentAddOn.ps1 VendorDeals
```

then `/reload` and open an Auction House. Slash command: `/vendordeals`.

Release: bump `## Version:` in `VendorDeals/VendorDeals.toc`; the user tags `vX.Y.Z` on
`main`, and `release.yml` publishes `VendorDeals.zip`.

## Rules

- Never buy, bid or post on the user's behalf. The addon only finds listings; buying goes
  through the normal AH UI.
- Respect the AH's replicate-scan cooldown: don't request a scan while one is active or
  while Auctionator owns it.
- Auctionator is optional: every path must work with it missing, and its internals can
  change, so guard what you read from it.
- Compare in copper and account for stack size (vendor price × count vs. buyout).
- The Forever API is undocumented. Only use functions confirmed by a ForeverAPIExplorer
  capture and say when you're assuming.
- The release workflow uses unpinned actions (`actions/checkout@v7`); when you touch it,
  pin to a full commit SHA with the version as a comment, as the other repos do.
- Commits and pushes need the user's go-ahead. Work on a branch.
