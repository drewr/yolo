## Open Learnings

## Open Decisions

## Session Notes
- spec loop completed (outcome: success) — chained to plan (job `gh-3`).
- plan loop completed (outcome: success) — chained to dev (job `gh-3`).
- Phase 1 done: `infra.Profile`/`awsArgsFor`/`awsTry`/`awsFor` + `*For` provisioners + `waitSsmOnline`; `session.SshTarget`/`sshArgs`/`splitSshArgs`; `datum.datumSsh` is now a wrapper; `keys.prepareIrohSession`/`recordIdentity`; flake `tools` gained `crane` and the description mentions EC2. Gates: `zig build test`, `zig fmt --check`, ReleaseSafe, `nix build` all pass; `yolo version` = `5a57506-dirty`.
- Commit covers Phase 1 of 5 (shared foundations): the two repo-wide learnings were promoted into `techContext.md` and `systemPatterns.md`.
