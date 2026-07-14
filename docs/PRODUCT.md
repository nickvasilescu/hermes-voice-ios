# PRODUCT

## What this is

A voice-first way to hand things off to Hermes. You talk; it listens,
responds naturally, and for anything that takes real work — booking
something, drafting something, checking on something from earlier —
delegates to Hermes and keeps the conversation going while that happens in
the background. You find out it's done the same way you asked for it: by
voice, whenever it's ready, not by switching to a different app to check a
status page.

## Who it's for

Someone who wants to talk to an assistant the way they'd talk to a capable
person on the phone — not type, not tap through menus — and who's fine
with real work happening asynchronously in the background rather than
blocking the conversation.

## The core loop

1. Open the app. It connects, the orb shows "Listening."
2. Say what you want. Realtime handles the back-and-forth naturally —
   clarifying questions, confirming details — same as it would with no
   Hermes involved at all.
3. Once there's enough to act on, it delegates to Hermes
   (`delegate_to_hermes`) and says so ("Got it, I'll get that booked") —
   it does not go silent while Hermes works.
4. The task shows up on the task rail immediately with a task id. You keep
   talking about other things if you want.
5. When Hermes reports progress or completion, the app narrates it back
   ("Table's booked for 7, confirmation's in your email") without you
   asking — this is the SSE → task rail → Realtime narration path.
6. If Hermes needs your say-so before doing something sensitive (spending
   money, sending something), it pauses and the assistant reads the
   pending action back to you and waits for an explicit yes/no before
   calling `approve_hermes_action` — never auto-approves.

## Design decisions and why

- **An orb, not a chat transcript.** The primary surface
  (`AmbientOrbView`) is one glanceable shape that communicates phase —
  listening / thinking / speaking / error — at a glance, not a scrolling
  log of every turn. Voice conversations don't need a transcript UI to
  feel legible; a phone screen full of text fights the voice-first premise.
- **The task rail is secondary and disposable.** It exists so a glance at
  the screen tells you what's in flight without asking out loud — not as
  a primary interaction surface. No detail view, no manual retry UI in
  this MVP (see `docs/ARCHITECTURE.md` "Known limitations") — those are
  reasonable v2 additions, not core to proving the voice loop.
- **Exactly five tools, on purpose.** Constraining Realtime to
  delegate/status/followup/cancel/approve (never a sixth "just this once"
  tool) keeps the boundary between "things Realtime can do" and "things
  Hermes can do" legible — see `CLAUDE.md`. If a capability doesn't fit
  one of the five, it belongs inside Hermes' own tool surface, not
  bolted onto Realtime.
- **Async by default, not a spinner.** Nothing in this product blocks the
  conversation waiting for Hermes. `delegate_to_hermes` returns a task id
  immediately; the app is designed around "keep talking, get told later,"
  not "wait here while I check."
- **Approval is a real interrupt, not a checkbox.** Sensitive actions
  pause Hermes and require the assistant to actually say what it's asking
  permission for and get a real answer — this is a product commitment
  (not just the technical 409-on-mismatch enforcement described in
  `docs/SECURITY.md`).

## Explicitly out of scope for this MVP

- Multi-turn task editing UI (the task rail is read-only glanceable state).
- Any non-voice input (typing, deep links to specific tasks).
- Multi-user / multi-device sync of `hermesSessionId` state — one
  per-install identifier today (see `docs/SECURITY.md` for the
  authentication gap this implies).
- Push notifications for task completion while the app isn't foregrounded
  — today, narration only happens while the app is open and connected.
- Anything about what Hermes itself can actually do end-to-end — that's a
  property of whatever `HermesProvider` a real deployment plugs in
  (`docs/ARCHITECTURE.md`), not of this app.
