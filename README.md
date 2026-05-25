# Self-Healing CI/CD Pipeline

A stateful agentic system that reacts to failed GitHub Actions runs by
**analyzing the failure**, **proposing a code fix**, and **posting a
repair pull-request comment** — gated by a self-rated confidence score so
low-certainty diagnoses never become noisy auto-PRs.

> Status: **15 / 15 tests passing** (9 unit · 6 end-to-end with mocked agents). Verified on Python 3.14.5 / LangGraph 1.2 / Pydantic 2.13.

---

## Architecture

```
GitHub Actions (upstream CI fails)
      └── workflow_run completed event
            └── .github/workflows/self-healing.yml
                  └── Docker sandbox  (non-root, read-only FS)
                        └── LangGraph state machine
                              START
                                └── parse_logs        (regex / structural)
                                  └── fetch_context   (GitHub contents API)
                                    └── diagnose      (Claude → AnalysisResult)
                                      └── gate        (confidence ≥ 0.80?)
                                        ├── propose_fix  (Claude → RepairProposal)
                                        │     └── report (post PR comment)
                                        └── report       (diagnostic-only)
                              END
```

Every node emits a structured JSON record to `pipeline.log`, giving you a
full audit trail of the agent's reasoning.

---

## Deliverables map

| Requested | Where |
|-----------|-------|
| State machine (LangGraph nodes + edges) | [`src/graph.py`](src/graph.py) |
| Diagnostic agent prompt | `DIAGNOSTIC_AGENT_PROMPT` in [`src/prompts.py`](src/prompts.py) |
| Fixer agent prompt | `FIXER_AGENT_PROMPT` in [`src/prompts.py`](src/prompts.py) |
| `AnalysisResult` Pydantic schema | [`src/models.py`](src/models.py) (line 54) |
| `RepairProposal` Pydantic schema | [`src/models.py`](src/models.py) (line 90) |
| GitHub workflow integration | [`.github/workflows/self-healing.yml`](.github/workflows/self-healing.yml) |
| Decision logging → `pipeline.log` | [`src/logger.py`](src/logger.py) |
| Dockerized sandbox | [`Dockerfile`](Dockerfile) |

---

## Project layout

```
self-healing-cicd/
├── .github/workflows/self-healing.yml   GitHub Action trigger
├── src/
│   ├── models.py            Pydantic schemas + LangGraph TypedDict state
│   ├── prompts.py           Diagnostic + Fixer prompts (with calibration rubric)
│   ├── tools.py             Deterministic log parsers, diff, verification script
│   ├── logger.py            JSON-line structured logger → pipeline.log
│   ├── github_client.py     GitHub REST API wrapper (logs, files, PR comments)
│   ├── agents.py            DiagnosticAgent + FixerAgent (Claude structured output)
│   ├── graph.py             LangGraph state machine (nodes + conditional edges)
│   └── main.py              CLI entry point — driven by env vars from the Action
├── tests/
│   ├── test_parser_and_models.py    Unit tests (parsers, Pydantic, diff)
│   └── test_graph_e2e.py            Graph tests with mocked agents/GitHub
├── Dockerfile               Non-root, read-only sandbox image
├── requirements.txt
└── README.md
```

---

## Confidence threshold (the safety mechanism)

The Diagnostic Agent self-scores its confidence in `[0.0, 1.0]` against
an explicit calibration table in the system prompt. The `gate` node
enforces:

| Confidence | Outcome |
|-----------|---------|
| ≥ 0.80 | Fixer Agent runs; PR comment includes a `git diff`, verification script, risk level. |
| < 0.80 | No fix is proposed. The comment is a **Diagnostic Report** explaining the ambiguities. |

The threshold is tunable via the `CONFIDENCE_THRESHOLD` env var (default
`0.80`).

---

## Safety boundaries

- **No execution.** The Fixer Agent emits a `verification_script`; it
  never runs the script itself. A separate (intentionally out-of-scope)
  consumer can run it inside the sandbox.
- **Sandboxed FS reads.** `tools.read_file_safely` resolves paths and
  refuses anything outside the repo root.
- **Trusted diff format.** Unified diffs are recomputed deterministically
  from `original_content` / `proposed_content` after the LLM returns —
  we never let the model format `--- a/<path>` headers.
- **Trusted verification script.** Test commands are deterministically
  wrapped in a `#!/bin/sh; set -eu` envelope; the LLM doesn't get to
  inject raw shell.
- **Non-root container.** The Docker image runs as a `agent` user with a
  read-only root FS and a small tmpfs at `/tmp`.

---

## Quickstart

### 1. Install

```bash
pip install -r requirements.txt
```

Python 3.12+ recommended (verified on 3.14.5).

### 2. Run the test suite

```bash
pytest tests/ -v
```

Expected output:

```
15 passed in 1.0s
```

### 3. Run against a real failed workflow (live mode)

```bash
export GITHUB_TOKEN=ghp_...                  # PR-write scope
export GITHUB_REPOSITORY=owner/name
export WORKFLOW_RUN_ID=123456789             # id of a FAILED run
export HEAD_SHA=abc1234...
export ANTHROPIC_API_KEY=sk-ant-...
# optional:
export CONFIDENCE_THRESHOLD=0.80
export PIPELINE_LOG_PATH=pipeline.log

python -m src.main
```

The agent prints a JSON summary on stdout, writes a record per decision
to `pipeline.log`, and (if a PR was found for the head SHA) posts a
comment with either the proposed fix or a diagnostic report.

### 4. Wire it into your repo

Copy `.github/workflows/self-healing.yml` into a target repo and add
`ANTHROPIC_API_KEY` as a repo secret. The workflow triggers on
`workflow_run.completed` of a workflow named `CI` — change that name to
match your upstream pipeline.

---

## Tests

| File | Covers |
|------|--------|
| `tests/test_parser_and_models.py` | Python / Jest / Go log parsers, unknown-fallback, Pydantic validation, diff generator, verification-script wrapper. |
| `tests/test_graph_e2e.py` | Full LangGraph with mocked `DiagnosticAgent` / `FixerAgent` / GitHub I/O. Covers high-confidence (fix-proposed), low-confidence (report-only), parser-fallback, and the gate boundary at 0.79 / 0.80 / 0.81. |

The agent-driven nodes use `with_structured_output(...)` so any LLM
response that doesn't match the Pydantic schema raises immediately — the
e2e suite exercises every path *without* making a live LLM call.

---

## Tuning the prompts

Both prompts live in [`src/prompts.py`](src/prompts.py). The diagnostic
prompt includes an explicit confidence-calibration table; if you find
the agent overconfident, tighten the rubric there rather than lowering
the threshold globally.

---

## License

Not yet specified — add a `LICENSE` file before publishing.
