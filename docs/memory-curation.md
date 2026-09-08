# Private Memory Curation and Search

Memory should improve continuity without turning every conversation into
permanent context. Never commit live `MEMORY.md`, `DREAMS.md`, daily notes,
wiki files, indexes, or transcripts to this repository.

Tagged references:
[memory](https://github.com/openclaw/openclaw/blob/v2026.9.1/docs/concepts/memory.md),
[builtin search](https://github.com/openclaw/openclaw/blob/v2026.9.1/docs/concepts/memory-builtin.md),
[active memory](https://github.com/openclaw/openclaw/blob/v2026.9.1/docs/concepts/active-memory.md),
[dreaming](https://github.com/openclaw/openclaw/blob/v2026.9.1/docs/concepts/dreaming.md), and
[memory wiki](https://github.com/openclaw/openclaw/blob/v2026.9.1/docs/plugins/memory-wiki.md).

## Privacy boundary

- The `main` agent explicitly enables cross-conversation recall from memory and
  session sources.
- OpenClaw limits that recall to the same agent's recognized private direct and
  persistent explicit UI conversations. Groups and channels are neither source
  nor destination; unknown, archived-without-context, other-agent, sandboxed,
  automation, heartbeat, and delegated sessions are excluded by runtime gates.
- `tools.sessions.visibility: "tree"` preserves native orchestration. The main
  agent sets `sandbox.sessionToolsVisibility: "all"` so its sandboxed Active
  Memory helper can pass the protected transcript-recall gate; the global
  `tree` boundary and memory-core's same-agent/private-chat checks still apply.
  The orchestrator retains the inherited `spawned` clamp.
- Active Memory targets `main` and only `direct`/`explicit` chats. It uses
  recent context, does not persist its temporary subagent transcript, bounds
  recall to 15 seconds and 220 characters, and logs timing/outcome rather than
  raw recalled content. Luna is the explicit recall model; the configured Sonnet
  `modelFallback` is only a last-resort model-resolution choice in `2026.9.1`,
  not runtime failover. Both are restricted by the plugin subagent allowlist.
- Memory-core admission excludes group/channel and email/Gmail/webhook sessions
  from dreaming ingestion. This is additive to OpenClaw's provenance gates and
  does not erase material already indexed.

## Builtin retrieval

The selected memory slot is `memory-core`, using GitHub Copilot
`text-embedding-3-small`. SQLite FTS and vector indexes are enabled with a
six-result/0.35-score query bound and embedding cache enabled.

In `2026.9.1`, hybrid BM25/vector retrieval, a 30-day decay for dated notes, and
MMR with lambda `0.7` are fixed maintained behavior, not writable schema keys.
Cache entry count, index identity, sync timing, and watcher timing likewise
have no supported tuning keys. The configured provider/model, tokenizer, and
vector setting are the durable index identity inputs. Do not invent retired
`memory.search.query.hybrid`, `memory.search.sync`, or store-driver keys.

## Curated files and dreaming

Keep `MEMORY.md` concise: durable preferences, current decisions, topic links,
and source/date/expiry where facts age. Put working notes in
`memory/YYYY-MM-DD.md` and durable detail in `memory/topics/<topic>.md`.

Memory-core dreaming runs daily in UTC with explicit light, REM, and deep
bounds. Only deep may promote to `MEMORY.md`. It rejects candidates that miss
score, recall-count, and query-diversity gates, excludes untrusted/system
provenance before the model prompt, limits snippet size, and rejects rewrites
that remove more than ten percent of prior entries. `DREAMS.md` and separate
phase reports make accepted changes reviewable. The approved Luna model is
allowlisted for these bounded plugin subagents.

## Memory Wiki

Memory Wiki runs in bridge mode with an agent-scoped native vault. It reads only
public memory artifacts tagged for that agent, never private memory-core paths.
URL ingest and Obsidian CLI access are disabled. Compilation preserves human
blocks and creates backlinks plus dashboards for contradictions, stale pages,
low confidence, and provenance/open-question review.

Run:

```bash
openclaw wiki status --agent main
openclaw wiki bridge import --agent main
openclaw wiki compile --agent main
openclaw wiki lint --agent main
```

## Review cadence

Weekly or after significant work:

1. run `openclaw memory status --deep --agent main`;
2. review recent daily notes and remove accidental sensitive fragments;
3. preview promotion with `openclaw memory promote`;
4. inspect `DREAMS.md`, then apply only grounded candidates;
5. import, compile, and lint the agent wiki;
6. review contradiction, staleness, provenance, and low-confidence reports;
7. run known-answer tests for direct recall and negative tests for group,
   channel, other-agent, automation, and Incognito leakage;
8. record aggregate quality and latency only, never private queries.

Use `openclaw memory forget` for supported removal workflows, then reindex and
verify. Memory output is evidence, not instruction authority.
