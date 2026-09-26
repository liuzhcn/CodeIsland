# Codex desktop customizations

This work is based on [wxtsky/CodeIsland](https://github.com/wxtsky/CodeIsland),
starting at commit `63013bfb5c4e948f7dfed3677ddcb1c930af9afa` (v1.0.33).
The upstream license and attribution are retained.

## Changes

- Open local Codex desktop and Codex-managed SSH sessions through a thread deep link.
- Preserve the latest user prompt in Codex cards and normalize multiline attachment prompts.
- Show session titles first, with a separate project label resolved from Codex project assignments.
- Include the remote Codex session title in the existing SSH hook payload.

The existing event transport remains in use. The remote hook reads title metadata
from the remote Codex database when an event fires; it does not add a background
log watcher or another completion-notification service.

## Build and test

Follow the upstream build prerequisites, then run:

```sh
swift test --filter 'CodexPromptTests|CodexDeepLinkTests|SessionTitleStoreTests|ChatMessageTextFormatterTests'
python3 Tests/RemoteHook/test_codex_title.py
SIGN_ID=- bash build.sh
```

The application is produced at `.build/release/CodeIsland.app`. The modified remote
hook is bundled with it. Configure SSH hosts in CodeIsland itself; no personal SSH
configuration or credentials are included here.

## Compatibility

The Codex deep link, project registry, session index and `state_5.sqlite` schema are
internal interfaces and can change. Missing remote title metadata does not stop hook
events from being sent. SSH forwarding and Codex hook approval still need to be
configured through the normal installation workflow.

Installing an official CodeIsland release replaces these customizations. Keep using
builds from the customization branch until the relevant changes are incorporated
upstream. Merging upstream source updates does not by itself rebuild the installed app.

## Upstream v1.0.35 integration (2026-09-25)

Merged upstream tag `v1.0.35` (`b444ae2`) while preserving the custom
Codex titles/deep links, compact selection, external-display layout,
remote reconciliation/deduplication, and protection for silent desktop turns.
The cleanup loop keeps both that protection and upstream's independent Cowork
settlement. Title-first cards honor the new Show project name switch; Codex
jumps also stop the new follow-up reminders.

Validation: full Swift suite (1,914 tests, 4 skipped, no failures), 52 focused
reminder/deep-link tests after the jump integration, and RemoteHook Python checks.
The previous source state is retained as `backup/before-v1.0.35-20260925`.

## Event-driven Codex task counts (2026-09-26)

Codex task lifecycle now comes from hooks and the running service's notifications.
Local desktop IPC supplies runtime snapshots and subsequent state changes; remote
connections attach to the existing app-server control socket, hydrate its loaded
threads once, and reread live metadata on status notifications. Reconnection
rehydrates live state. No Codex rollout/state-DB discovery is scheduled, and
transcript appends cannot change a Codex card's running/idle state. Transcript
text/model/checklist enrichment remains separate from lifecycle.

The bridge and process detection recognize ChatGPT's nested CodexCLI.app binary.
Desktop hooks therefore share the same `codexapp:` identity as live desktop state,
including when `__CFBundleIdentifier` is absent. Existing local snapshots supply
identities only; live IPC refreshes their status. Newly started local sessions are
discovered through hooks. If CodeIsland was absent for an entire session's first
activity and has no saved identity, that session appears on its next hook.

Validation: 1,916 Swift tests (4 skipped), remote title checks, websocket framing
checks, and read-only connections to the live desktop IPC and remote app-server.
