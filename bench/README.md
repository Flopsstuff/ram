# bench — embedding model comparison

A standalone harness for choosing the embedding model behind the vault's semantic search.
It embeds a folder of markdown notes with each candidate model, runs a set of queries with
known answers, and reports retrieval quality, latency and cost side by side.

It does not touch the deployed server. The chunking (heading-delimited sections, frontmatter
stripped, ~2000-char cap) and the two text formats mirror what `markdown-vault-mcp` sends to
its embedder, so results carry over to the deployment:

- `plain`: the section body as-is. This is the server default (text format v1).
- `ctx`: note title, section heading, blank line, body. This is `EMBED_CONTEXT=true` (v2).

Remote models are called through OpenRouter's OpenAI-compatible `/embeddings` endpoint in
exactly the shape the server's `openai` provider uses: a plain input list, no task type, no
instruction prefix, no `dimensions`. Models tuned for asymmetric query/document encoding
(Gemini, Qwen3) therefore score here as they would in the deployment, not as on leaderboards.

## Privacy: what is committed and what is not

Only code, this README and the synthetic `sample/` are committed. Everything derived from
the real vault lives under `bench/.data/`, which `bench/.gitignore` excludes:

| Path | What |
|---|---|
| `.data/vault/` | clone of the vault repo, the real corpus |
| `.data/queries.json` | real queries with expected note paths |
| `.data/cache/` | embedding cache per model, so re-runs are free |
| `.data/results/<timestamp>/` | `summary.json` and per-query ranks / top-3 |
| `.data/venv/` | Python environment |
| `.env` | `OPENROUTER_API_KEY=…`, `GEMINI_API_KEY=…` |

Running the bench sends the corpus text to OpenRouter and on to each model's provider.

## Setup

```bash
cd bench
python3 -m venv .data/venv
.data/venv/bin/pip install "openai>=1.40" "numpy>=1.26" "fastembed>=0.5"
echo 'OPENROUTER_API_KEY=sk-or-…' > .env && chmod 600 .env
gh repo clone <owner>/<vault-repo> .data/vault
```

## Run

```bash
# synthetic sample, no key needed for local models
.data/venv/bin/python bench.py --corpus sample/notes --queries sample/queries.example.json \
    --models local:BAAI/bge-small-en-v1.5

# the real comparison (default model list, both text formats)
.data/venv/bin/python bench.py --corpus .data/vault --queries .data/queries.json
```

Options:
- `--models`: a comma-separated list of model specs:
  - `or:<id>` — OpenRouter, needs `OPENROUTER_API_KEY`.
  - `gai:<id>` — Google AI Studio directly through the Gemini API's OpenAI-compatible endpoint,
    needs `GEMINI_API_KEY`.
  - `local:<fastembed-id>` — fastembed on this machine.
- `--variants plain,ctx`.
- `--latency-n 20`: number of single-query calls per model (0 skips the latency test).
- `--latency-only`: skip the corpus and only time single-query calls. This is the cheap way to
  compare two routes to the same model, for example `or:google/gemini-embedding-2` against
  `gai:gemini-embedding-2`.

## Queries file

```json
[{"q": "кофеварка мигает красным, что делать", "relevant": ["coffee-machine.md"]}]
```

`relevant` lists note paths relative to `--corpus`. A query counts at the rank of its
best-ranked relevant note. Write queries the way an agent would ask, paraphrased rather than
copied from the note, otherwise every model looks perfect.

## Reading the output

- **R@1 / R@5:** share of queries whose answer is the top note / in the top 5.
- **MRR:** mean of 1/rank, counting ranks up to 10. The single best summary number.
- **p50 / p95 ms:** one uncached single-query embed call, sequential, from this machine.
  This is the latency every semantic search pays.
- **corpus_s / tokens / $:** a full uncached pass over the corpus, which is what a model
  switch costs. Kept from the first run, so cached re-runs still show it.

Notes are ranked by their best-matching chunk (max cosine), as vault search does.
