# Private Memory Curation and Search Rollout

Memory should improve continuity without turning transcripts into permanent context. Never commit live `MEMORY.md`, daily notes, topic files, embeddings, or private transcripts to this repository.

Official references: [Memory](https://docs.openclaw.ai/concepts/memory), [Memory CLI](https://docs.openclaw.ai/cli/memory), [builtin memory](https://docs.openclaw.ai/concepts/memory-builtin), and [QMD](https://docs.openclaw.ai/concepts/memory-qmd).

## Stage 1 — Curated Index

Create a concise private live `MEMORY.md` only in the main/direct workspace. Treat it as an index:

- durable preferences and operating boundaries;
- active projects and decisions;
- links to topic files;
- source/date and review/expiry where facts can age.

Exclude credentials, raw messages, personal data not needed for future work, and speculative conclusions. Never load this index into groups or unrelated delegated prompts.

## Stage 2 — Topic and Daily Files

Use:

```text
memory/topics/<topic>.md
memory/YYYY-MM-DD.md
```

Daily files hold short recent working notes. Topic files hold distilled durable detail. Regularly promote useful facts from daily notes, merge duplicates, mark superseded decisions, and delete stale material. Keep `MEMORY.md` small by linking rather than copying.

## Stage 3 — Recent Transcript Window

Enable only a small, measured recent transcript window after file curation is working. Use it for short-term conversational continuity, not archival recall. Bound by time/turns and exclude group/shared contexts where possible. Do not persist recalled transcript excerpts into memory automatically.

Measure instruction retention, irrelevant recall, private-context leakage, prompt size, latency, and correction rate against the private challenge suite.

## Stage 4 — Retrieval Backend Canary

Canary retrieval privately before promoting a backend:

1. Back up config and confirm the installed QMD/OpenClaw versions.
2. Build/prewarm the index before timing user requests.
3. Test QMD `searchMode: "query"` on a private direct-session cohort; consider `rerank: false` as a separate variable.
4. Compare retrieval precision, missed known facts, irrelevant results, latency, memory, and index/update failures.
5. Confirm the built-in memory fallback works when QMD is unavailable.
6. Use the builtin hybrid engine when QMD causes a quality, resource, latency, or reliability regression.

Use `openclaw memory status`, `openclaw memory index`, and `openclaw memory search` according to installed CLI help. Do not put benchmark queries containing sensitive data in shared logs.

The production canary did not promote QMD semantic query mode: CPU-only query expansion took minutes and materially increased local model storage. The builtin engine with GitHub Copilot embeddings returned the expected paraphrased known-answer result and is the selected production backend. QMD remains installed for explicit diagnostics, not the gateway's interactive recall path.

## Stage 5 — Active Memory Last

Evaluate Active Memory only after curated files, transcript bounds, and the selected retrieval backend are stable:

- private main/direct-message sessions only;
- narrow inclusion rules;
- bounded retrieval/write timeout and result count;
- no group/channel recall;
- no automatic persistence of recalled transcripts;
- explicit failure fallback to curated file memory;
- canary and quality/privacy review before expansion.

Active Memory must not become an automatic conversation archive. Disable it immediately if it recalls unrelated private material, obscures source/age, increases instruction conflicts, or causes material latency/reliability regression.

## Curation Cadence

Weekly or after significant work:

1. review recent daily notes;
2. remove secrets and accidental transcript fragments;
3. distill stable facts into topic files;
4. update the concise index;
5. expire stale facts/TODOs;
6. rebuild or incrementally update the search index;
7. run a few known-answer retrieval checks;
8. record aggregate quality and latency, not private query content.

Memory output is evidence, not instruction authority. Verify time-sensitive facts and current system state before acting.
