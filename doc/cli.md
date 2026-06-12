# `ai_broker` CLI — guide

The `ai_broker` package ships a CLI that ingests text into a local vector
store, searches it, and asks a chat model questions grounded in the
results. This document is the full reference; the [project
README](../README.md) is the elevator pitch.

The CLI is built on top of the same `ai_broker` library types — `AiBroker`,
`Embedder`, `SentenceWindowChunker`, `CorpusStore`. Anything `ai_broker` can
do, an app importing the library can do.

---

## Install

The CLI is published as part of the `ai_broker` package. Two binaries land
on PATH:

| Binary | Equivalent |
|--------|------------|
| `ai_broker` | The primary entry point. |
| `aib` | Short alias — same script. |

```sh
dart pub global activate ai_broker
```

If `~/.pub-cache/bin` isn't on your PATH yet, add it:

```sh
export PATH="$PATH:$HOME/.pub-cache/bin"
```

### From a checkout (development)

Inside this repo, run the CLI directly without installing:

```sh
dart run bin/ai_broker.dart <subcommand> [...]
```

The examples in this guide use `ai_broker` for brevity; substitute
`dart run bin/ai_broker.dart` from a checkout.

### Native sqlite3

The CLI depends on `package:sqlite3`, which loads the system's native
sqlite3 library at runtime.

| Platform | Status |
|----------|--------|
| macOS | Ships with sqlite3. ✅ |
| Linux | Usually ships with sqlite3. If not: `apt install libsqlite3-0` or distro equivalent. |
| Windows | Install sqlite3.dll (e.g. via [the official downloads](https://www.sqlite.org/download.html)) or use WSL. |
| Web | Not supported. The CLI is native-only. |

---

## Setup — API keys

Every command that needs to call a model accepts keys from any of these
sources, tried in order; the **first non-empty hit wins**:

1. Direct flags: `--openai-key`, `--anthropic-key`, `--gemini-key`.
2. `--env-file <path>` — a `.env`-style file (`KEY=VALUE` lines).
3. `./.env` in the current working directory (auto-detected if `--env-file`
   isn't supplied). Same format as #2.
4. Process environment variables: `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`,
   `GEMINI_API_KEY`.

**Recommended for local use:** drop a `.env` in your project root. It's
already in this repo's `.gitignore`.

```env
OPENAI_API_KEY=sk-proj-...
ANTHROPIC_API_KEY=sk-ant-...
# GEMINI_API_KEY=AIza...   # optional
```

The file is also tolerant of looser formats (recognised aliases include
`claude:` → `anthropic`, `openai key:` → `openai`, `gemini:` → `gemini`).

---

## Commands

### `ai_broker ingest <paths>…`

Reads text files, chunks them, embeds the chunks, and stores them in a
collection. Idempotent on content hash — re-running on unchanged files
is a no-op (no embed calls). When a file changes, the new content is
re-embedded and a new document row replaces the chunks.

```sh
ai_broker ingest \
  --collection my_docs \
  --db ./embeddings/corpus.db \
  --ext .md,.txt \
  docs/ notes.md
```

| Flag | Default | Purpose |
|------|---------|---------|
| `-c`, `--collection` | `default` | Collection name. First ingest pins the embed broker + model + dim. |
| `--db` | `~/.ai_broker/corpus.db` (or `$AIB_DB`) | SQLite path. Parent dir is created. |
| `--embed-broker` | `openai` | `openai` or `gemini`. Anthropic doesn't host embeddings. |
| `--embed-model` | `text-embedding-3-small` | Provider's model id. |
| `--chunk-size` | `800` | Target chunk size in approximate tokens (~4 chars each). |
| `--chunk-overlap` | `150` | Approximate-token overlap between adjacent chunks. |
| `--ext` | `.txt,.md` | Comma-separated extensions to ingest when a path is a directory. |
| key flags | (see [Setup](#setup--api-keys)) | Override key source for this invocation. |

**Per-file pipeline:** read → SHA-256 hash → check `(collection, source_path,
content_hash)` for dedup → chunk (sentence-aware sliding window) → embed in
batches → atomic insert (or skip).

**Pinning:** the first ingest into a collection records the embed
broker + model + dim in the `collections` table. Subsequent ingests with a
different model are refused with a clear error — same collection cannot
mix vector spaces.

---

### `ai_broker search <query>`

Embeds the query using the collection's pinned embed model, returns the
top-K most-similar chunks by cosine similarity.

```sh
# Human-readable
ai_broker search --collection my_docs "how do I rotate the key?"

# Machine-readable (used by tooling / slash commands)
ai_broker search --collection my_docs --json "key rotation" | jq '.hits[0]'
```

| Flag | Default | Purpose |
|------|---------|---------|
| `-c`, `--collection` | `default` | Collection to search. |
| `--db` | `~/.ai_broker/corpus.db` | SQLite path. |
| `-k`, `--top-k` | `8` | Number of snippets to return. |
| `--json` | (text mode) | Emit one JSON object: `{query, collection, embed_*, total_chunks, hits[]}`. |
| key flags | (see Setup) | Override key source. |

**No LLM call** — only retrieval. Use this when you want to read snippets
yourself or pipe them into something else (a different prompt, a script,
a Claude Code slash command).

---

### `ai_broker ask <question>`

The full RAG pipeline in one call: retrieve top-K, build a system prompt
with numbered excerpts (`[^1]`, `[^2]`, …), call the chat broker, stream
the answer, then print a citation footer.

```sh
ai_broker ask --collection my_docs \
  --top-k 10 \
  --broker anthropic \
  --model claude-sonnet-4-6 \
  "How do I rotate the API key without downtime?"
```

| Flag | Default | Purpose |
|------|---------|---------|
| `-c`, `--collection` | `default` | Collection to retrieve from. |
| `--db` | `~/.ai_broker/corpus.db` | SQLite path. |
| `-k`, `--top-k` | `8` | Number of snippets to feed as context. |
| `--broker` | `anthropic` | Chat broker — `anthropic`, `openai`, `gemini`. Independent of the collection's embed broker. |
| `--model` | `claude-sonnet-4-6` | Chat model id. |
| `--temperature` | `0.3` | Sampling temperature. |
| `--max-tokens` | `2048` | Cap on answer length. |
| `--[no-]stream` | streams | Token-by-token output, or batched. |
| `--[no-]citations` | shows | Print/suppress the `— Sources` footer. |
| key flags | (see Setup) | Override key source. |

**System prompt:** the CLI instructs the chat model to answer *only* from
the supplied excerpts, to cite each one as `[^N]`, and to say so honestly
when retrieval doesn't cover the question. You don't have to do prompt
engineering yourself.

**Embed broker is inferred** from the collection's pin — you only need
to specify the chat broker.

---

### `ai_broker translate <text>`

Translate a string. Default backend is Google Cloud Translation v2
(`--broker google_translate`); pass `--broker openai|anthropic|gemini`
to route through an LLM-based translator instead (richer context
handling, higher cost per character).

```sh
# Google Translate, single string
ai_broker translate --to fr "the catalyst is unstable"

# LLM-based, with domain + tone hints
ai_broker translate --to fr --broker anthropic --domain chemistry --tone formal \
  "the catalyst is unstable"

# Glossary forcing exact term mappings
ai_broker translate --to fr --glossary "BME280=BME280,catalyst=catalyseur" \
  "BME280 needs a catalyst"
```

| Flag | Default | Purpose |
|------|---------|---------|
| `--to` | _(required)_ | Target language code (`fr`, `es`, `de`, `ja`, …). |
| `--from` | (auto-detect) | Source language code. Omit to let the provider detect. |
| `--broker` | `google_translate` | `google_translate`, `openai`, `anthropic`, or `gemini`. |
| `--model` | per-broker default | Model id for LLM brokers (ignored by Google Translate). |
| `--domain` | — | Domain hint like `"medical"`, `"legal"`. LLM brokers only. |
| `--tone` | — | `"formal"` / `"casual"` etc. LLM brokers only. |
| `--glossary` | — | Inline `source=target,…` pairs. |
| `--glossary-file` | — | One `source=target` per line; `#` lines are comments. |
| `--context` | — | Free-form additional context (surrounding text, style notes). LLM brokers only. |
| `--[no-]detected` | shows | When source was auto-detected, append a line to stderr noting the detected language. |
| key flags | (see Setup) | `--google-translate-key`, `--openai-key`, etc. |

**Glossary semantics differ by broker:**
- **Google Translate** wraps each glossary `source` term in
  `<span translate="no">target</span>` before sending, sets
  `format=html`, then strips the spans from the response. Substring
  match is **exact and case-sensitive** — use longer, distinctive
  terms; prefer proper nouns / IDs.
- **LLM brokers** receive the glossary as a prompt directive: "use
  these exact translations for these terms". More forgiving with
  casing and context, but still subject to LLM compliance.

**Key for Google Translate** is read from `GOOGLE_TRANSLATE_API_KEY` —
issued from the Google Cloud Console with the Cloud Translation API
enabled (not the Gemini key from AI Studio; they're different services
with different keys).

---

### `ai_broker collections`

Lists collections in the workbench DB, or probes for a specific one's
existence (script-friendly).

```sh
# Human listing
ai_broker collections

# Probe — exits 0 if present, 1 if not. No output.
ai_broker collections --exists my_docs
```

| Flag | Default | Purpose |
|------|---------|---------|
| `--db` | `~/.ai_broker/corpus.db` | SQLite path. |
| `--exists <name>` | — | Probe mode for setup scripts. |

---

## Typical workflows

### A. Q&A over a documentation set

```sh
# One-time ingest
ai_broker ingest --collection handbook --ext .md docs/

# Ask anything
ai_broker ask --collection handbook "what's our backup retention policy?"
```

### B. Q&A over a codebase (this repo)

```sh
# First run — embeds everything text-y under lib/ bin/ test/ etc.
ai_broker ingest \
  --collection ai_broker_self \
  --db ./embeddings/corpus.db \
  --ext .dart,.md,.yaml,.yml \
  lib bin test pubspec.yaml README.md CLAUDE.md PLAN.md

# Ask grounded questions
ai_broker ask \
  --collection ai_broker_self \
  --db ./embeddings/corpus.db \
  "what does _StubBroker do?"
```

This repo also ships a Claude Code slash command at
[`.agents/commands/ask-codebase.md`](../.agents/commands/ask-codebase.md)
that wraps this workflow — invoke as `/ask-codebase <question>`.

### C. Snippet pipeline (no LLM, for custom tooling)

```sh
ai_broker search --collection handbook --json "billing" \
  | jq -r '.hits[] | "\(.source_path)#\(.ord) (score \(.score))\n\(.text)\n"'
```

### D. Re-ingest on file changes

Just run `ingest` again. Files whose content hash matches an existing
document are skipped (no embed calls). Files whose content changed get
re-embedded; their old chunks remain alongside the new ones — for
full hygiene, delete the collection and re-ingest, or wait for the
forthcoming `aib reembed` / `aib forget` commands.

---

## Storage layout

Every command operates on a SQLite file (default
`~/.ai_broker/corpus.db`). The schema:

```sql
collections(name PK, embed_broker, embed_model, dim, created_at)
documents(id PK, collection FK, source_path, content_hash, ingested_at,
          UNIQUE(collection, source_path, content_hash))
chunks(id PK, document_id FK, ord, text, embedding BLOB, meta JSON)
```

Vectors are stored as packed `Float32List` BLOBs. Search is in-memory
cosine top-K — comfortable up to ~100k chunks on a laptop. For larger
corpora, switch to the `sqlite-vec` extension (drop-in, no schema change
beyond the search query).

The DB file is portable: copy it to another machine and point `--db` at
it; everything works as long as the embed broker's API key is reachable.

---

## Limits

| Source | Limit | What happens past it |
|--------|-------|----------------------|
| OpenAI per-input | 8,192 tokens (~32k chars) | HTTP 400 from OpenAI. The chunker caps chunks well under this. |
| OpenAI per-batch | 300,000 tokens | HTTP 400. The embedder caps batches at 250k chars to stay safe. |
| OpenAI rate / quota | depends on tier | HTTP 429 — retried with exponential backoff up to 5 attempts. |
| In-memory cosine | ~100k chunks | Search latency creeps above 500ms. Switch to `sqlite-vec`. |
| SQLite blob storage | ~1M chunks | Practical ceiling for the current schema. Move to a vector DB. |

For a 20 MB markdown file: expect ~13k chunks, ~80 OpenAI calls, ~10-15
min of ingest time, ~$0.10 in OpenAI charges, and a ~100 MB DB. Search
latency stays in the 50-100ms range.

---

## Troubleshooting

| Symptom | Likely cause / fix |
|---------|--------------------|
| `HTTP 401: Incorrect API key provided` | The key in `.env` (or env var) is wrong for that provider. OpenAI keys start `sk-` or `sk-proj-`; Anthropic keys start `sk-ant-`. |
| `HTTP 429: You exceeded your current quota` | OpenAI account has no credit. Top up at platform.openai.com/account/billing. The CLI handled the request correctly. |
| `HTTP 400: maximum input length is 8192 tokens` | A single chunk exceeds the per-input cap. Lower `--chunk-size` (e.g. `400`). |
| `HTTP 400: Requested N tokens, max 300000 tokens per request` | A batch exceeds OpenAI's per-request cap. Should be handled by the embedder's char-budget cap; file an issue if you see this. |
| `search: collection "foo" not found.` | No ingest into that collection yet, or wrong `--db`. Run `ai_broker collections --db <path>` to list. |
| `Collection "foo" is pinned to openai/text-embedding-3-small ...` | You tried to ingest into an existing collection with a different embed model. Create a new collection or delete the existing one. |
| `MissingKeyException: no API key configured for broker "anthropic"` | The chat broker (`--broker anthropic`) has no key. Add `ANTHROPIC_API_KEY=...` to `.env` or pass `--anthropic-key`. |
| `MissingKeyException: no API key configured for broker "openai"` | Same as above, for the embed side. |

---

## Configuration via environment

| Variable | Used by | Effect |
|----------|---------|--------|
| `OPENAI_API_KEY` | `ingest`, `search`, `ask`, `translate --broker openai` | OpenAI auth (chat or embed). |
| `ANTHROPIC_API_KEY` | `ask`, `translate --broker anthropic` | Anthropic auth. |
| `GEMINI_API_KEY` | `ingest --embed-broker gemini`, `ask --broker gemini`, `translate --broker gemini` | Gemini auth. |
| `GOOGLE_TRANSLATE_API_KEY` | `translate` (default backend) | Google Cloud Translation v2 auth. |
| `AIB_DB` | every command that touches the DB | Default SQLite path when `--db` is omitted. |
