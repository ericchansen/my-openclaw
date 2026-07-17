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
- tasks versus cron semantics;
- latency and timeout handling;
- explicit model fallback observability.

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
| Task/cron | wrong primitive | works with caveat | correct durable primitive |
| Latency | timeout/no result | slow but bounded | responsive within target |
| Fallback | silent/broken | fallback works | explicit and observable |

Critical instruction, privacy, authentication, or destructive-action violations are automatic failures regardless of total. Use blinded scoring where practical and record rationale plus reproducible evidence.

## Model Matrix

Run the same suite with:

| Candidate | Thinking/effort |
|---|---|
| Claude Opus 4.6 | off |
| Claude Opus 4.8 | off |
| Claude Sonnet 5 | high |
| GPT-5.6 Sol | high |

Provider vocabularies differ. Confirm authentication, model IDs, entitlement, and the reasoning levels exposed by the installed transport before a run. A catalog entry is not proof of availability.

## Experimental Control

Change one variable at a time:

1. Pin OpenClaw version, workspace revision, config, tools, fixtures, channel, and timeout.
2. Warm the same caches or record cold/warm state.
3. Run cases in randomized order with a new isolated session per case.
4. Repeat enough cases to separate a model difference from run variance.
5. Record exact selected model, fallback used, tokens/context, latency, errors, and score evidence.
6. Investigate regressions before averaging them away.

Test pruning, Tool Search, QMD, Active Memory, and model promotion as separate experiments. Do not combine a model change with a memory/config change.

## Promotion Gate

Promote only when the candidate:

- has no critical failures;
- improves instruction retention, completion, synthesis, and verification;
- does not regress channel/task safety;
- completes within bounded time;
- has a tested explicit fallback path;
- wins on quality before latency/cost are used as tie-breakers.

Canary in a private direct session, then one low-risk workflow, before broad rollout. Preserve raw private benchmark artifacts only for the minimum review period; retain an aggregate decision record without prompts or transcripts.

## Current Promotion Decision

The private 2026-07 challenge run found both `github-copilot/claude-sonnet-5` and `github-copilot/gpt-5.6-sol` with high reasoning passed the final bounded two-child orchestration case; Sonnet initially won the latency tie-break. On 2026-07-17, the user selected Sol as the consistent interactive control plane and preferred quality over that latency difference. The production policy therefore promotes Sol with high thinking, retains Sonnet 5 as the explicit failure fallback, uses Luna/low only for bounded low-risk background work, and requires explicit Sol/high selection for complex delegated or scheduled work. Live canaries confirmed default Sol/high resolution, direct Luna/low execution, and a native parent-to-default-Luna child handoff. The installed Copilot transport rejects `ultra` for Sol and exposes `high` as its strongest supported level.
