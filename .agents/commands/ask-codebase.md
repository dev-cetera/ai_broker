---
description: Ask a question about this codebase using local embeddings + a grounded LLM answer. Auto-ingests on first run; idempotent thereafter. The CLI auto-loads API keys from ./.env — keys never enter Claude's context.
argument-hint: <your question about the codebase>
allowed-tools: Bash
---

# /ask-codebase — RAG-grounded Q&A on the ai_broker repo

The user's question is at the bottom of this prompt. Run the steps in
order, then surface the answer the CLI produced.

## Key handling — read this first

**Do not touch keys.** The CLI auto-loads `./.env` (gitignored). Don't
read it, parse it, echo it, or export anything. Just run the commands
below.

## Step 1 — Ingest if needed (idempotent)

Probe whether the embeddings already exist; ingest only on first run:

```bash
if ! dart run bin/ai_broker.dart collections --db ./embeddings/corpus.db --exists ai_broker_self 2>/dev/null; then
  echo ">>> first run — ingesting codebase (this takes a minute) ..."
  dart run bin/ai_broker.dart ingest \
    --collection ai_broker_self \
    --db ./embeddings/corpus.db \
    --ext .dart,.md,.yaml,.yml \
    lib bin test pubspec.yaml README.md CLAUDE.md PLAN.md CHANGELOG.md analysis_options.yaml
fi
```

The collection is named `ai_broker_self` and lives in
`./embeddings/corpus.db` (gitignored). Re-running this command reuses
the existing index — re-ingestion only happens if a file's content hash
changes.

## Step 2 — Ask

Run the one-shot RAG command. It embeds the question with the
collection's pinned embed model, retrieves top-K snippets, sends them
as system context to Anthropic Claude (the chat broker), and streams a
grounded answer with `[^N]` citations followed by a `— Sources` block:

```bash
dart run bin/ai_broker.dart ask \
  --collection ai_broker_self \
  --db ./embeddings/corpus.db \
  --top-k 12 \
  --max-tokens 1500 \
  "$ARGUMENTS"
```

## Step 3 — Surface

Show the user the CLI's output verbatim. The CLI's chat broker already
produced a grounded, cited answer — **do not paraphrase or re-answer
the question yourself**. If the CLI emitted "the excerpts don't contain
enough information…", relay that honestly; do not fall back to your
own prior knowledge of the repo.

If the CLI errored (HTTP 401 from a missing/wrong key, HTTP 429 from
quota exhaustion, etc.), surface the error message and stop.

> **Heads-up on key format.** Embeddings go through OpenAI by default
> (`text-embedding-3-small`); chat goes through Anthropic
> (`claude-sonnet-4-6`). If either key in `.env` is missing or wrong,
> the corresponding step will surface a clean HTTP 401. To switch the
> embed broker to Gemini, edit this slash command and add
> `--embed-broker gemini --embed-model text-embedding-004` to the
> `ingest` line, plus create a fresh collection name. To switch the
> chat broker, pass `--broker openai --model gpt-4o` (or similar) on
> the `ask` line.

The user's question:

$ARGUMENTS
