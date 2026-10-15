# Private Quality Challenge Suite

Benchmark before changing the production primary model. Optimize quality first, then latency/cost. Keep prompts, transcripts, scores, and user data outside the repository.

## Build the Suite

Select 10–20 real requests that previously failed or required substantial correction. Remove credentials and unnecessary personal data while preserving the failure mechanism. Include a mix of:

- long instruction/scope retention;
- multi-step completion and recovery;
- appropriate plan creation/update;
- delegation choice and bounds;
- child handoff and parent synthesis;
- independent verification;
- context pruning/long-session behavior;
- tool discovery and correct tool use;
- channel-safe response behavior;
- tasks versus automation semantics;
- latency and timeout handling;
- inherited default model identity with no fallback routes.

Store a private case ID, prompt, fixtures, expected outcome, hard constraints, completion tests, and the historical failure. Do not commit personal memory or transcripts.

## Scorecard

Score each dimension 0–4 using evidence:

| Dimension | 0 | 2 | 4 |
|---|---|---|---|
| Completion | no useful outcome | partial/manual repair | fully achieved |
| Instruction retention | violates critical constraint | minor drift | all constraints held |
| Plan | absent/misleading | usable but stale | concise and evidence-updated |
| Delegation | harmful/unbounded | mixed | only independent bounded lanes |
| Handoff | raw/lost | usable evidence | complete concise evidence |
| Synthesis | forwards child | partial integration | parent resolves and owns |
| Verification | none | command-only | completion/user experience tested |
| Context | loses prior requirements | one recoverable miss | retains/prunes correctly |
| Tool use | unsafe/wrong | works with waste | correct, safe, efficient |
| Channel safety | leak/wrong destination | unclear | correct audience and privacy |
| Task/automation | wrong primitive | works with caveat | correct durable primitive |
| Latency | timeout/no result | slow but bounded | responsive within target |
| Model inheritance | alternate task route | unclear identity | verified native default |

Critical instruction, privacy, authentication, or destructive-action violations are automatic failures regardless of total. Use blinded scoring where practical and record rationale plus reproducible evidence.

## Model Policy

The configured task model is only `github-copilot/gpt-6.1-sol`, inherited from
`agents.defaults.model`. The bundled-provider metadata overlay declares Sol's
reasoning capabilities without replacing its endpoint or authentication.
Do not add aliases, alternate model catalogs, per-task pins, or fallback routes
for benchmarks. The native single-model access policy remains
in force. Confirm authentication and actual default inference before a run.

## Experimental Control

Change one variable at a time:

1. Pin OpenClaw version, workspace revision, config, tools, fixtures, channel, and timeout.
2. Warm the same caches or record cold/warm state.
3. Run cases in randomized order with a new isolated session per case.
4. Repeat enough cases to separate a quality difference from run variance.
5. Record exact inherited model, tokens/context, latency, errors, and score evidence.
6. Investigate regressions before averaging them away.

Test pruning, Tool Search, builtin retrieval, Active Memory, and model promotion as separate experiments. Do not combine a model change with a memory/config change.

## Promotion Gate

Promote only when the candidate:

- has no critical failures;
- improves instruction retention, completion, synthesis, and verification;
- does not regress channel/task safety;
- completes within bounded time;
- uses the inherited model without fallback routing;
- wins on quality before latency/cost are used as tie-breakers.

Canary in a private direct session, then one low-risk workflow, before broad rollout. Preserve raw private benchmark artifacts only for the minimum review period; retain an aggregate decision record without prompts or transcripts.

## Current Desired State

One native Sol 6.1 default serves interactive, agent, subagent, hook, automation,
and memory tasks. `utilityModel: ""` disables automatic small-model derivation.
Native plugin `allowedModels` safeguards allow only Sol 6.1. The vector encoder
`text-embedding-3-small` is not a task model and retains its existing auth.

The template and quality configuration declare Sol as a reasoning model through
`models.providers.github-copilot.models`, leaving the bundled endpoint and
authentication unchanged. Accepted efforts are `low`, `medium`, `high`, `xhigh`,
and `max`; `minimal` maps to `low`, and `off` is unavailable. Interactive turns
default to `xhigh`; the availability probe uses `low`. Acceptance requires an
actual human-channel request with successful inference and delivered output,
not only Gateway health or a CLI turn with an explicit thinking override.

Historical model experiments remain in Git history, not active desired-state
instructions or configuration.
