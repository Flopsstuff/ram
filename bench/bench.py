#!/usr/bin/env python3
"""Compare embedding models on a markdown corpus: retrieval quality, latency, cost.

Standalone: needs only a folder of .md notes, a queries file and (for remote
models) an OpenRouter key in bench/.env. It does not talk to the deployed
server; the chunking and the two text formats mirror what markdown-vault-mcp
sends to its embedder, so the numbers carry over to the deployment.

    python bench.py --corpus .data/vault --queries .data/queries.json
    python bench.py --corpus sample --queries sample/queries.example.json

Queries file: JSON list of {"q": "<query>", "relevant": ["<path.md>", ...]}.
A query counts as answered at the rank of its best-ranked relevant note.
Notes are ranked by their best-matching chunk (max cosine), as in vault search.

Everything a run produces (embedding cache, per-query results) goes to --data,
default bench/.data/, which is gitignored.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sqlite3
import statistics
import sys
import time
from dataclasses import dataclass
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent

# OpenAI-compatible /embeddings endpoints, keyed by the model-spec prefix.
#   or:<id>   OpenRouter            e.g. or:google/gemini-embedding-2
#   gai:<id>  Google AI Studio      e.g. gai:gemini-embedding-2 (Gemini API's
#             OpenAI-compatibility layer — the same base URL the server's
#             `openai` provider would be pointed at for a direct Gemini setup)
ENDPOINTS = {
    "or": ("https://openrouter.ai/api/v1", "OPENROUTER_API_KEY"),
    "gai": ("https://generativelanguage.googleapis.com/v1beta/openai/", "GEMINI_API_KEY"),
}

DEFAULT_MODELS = [
    "or:google/gemini-embedding-2",
    "or:google/gemini-embedding-001",
    "or:qwen/qwen3-embedding-8b",
    "or:qwen/qwen3-embedding-4b",
    "or:openai/text-embedding-3-large",
    "local:sentence-transformers/paraphrase-multilingual-mpnet-base-v2",
    "local:BAAI/bge-small-en-v1.5",
]
VARIANTS = ("plain", "ctx")
MAX_CHUNK_CHARS = 2000
BATCH = 32


# --------------------------------------------------------------------------- corpus


@dataclass(frozen=True)
class Chunk:
    path: str
    title: str
    heading: str | None
    content: str
    first: bool

    def text(self, variant: str) -> str:
        """The string the server would embed for this chunk.

        plain = server default (text format v1): the section body as-is.
        ctx   = EMBED_CONTEXT=true (v2): title, heading, blank line, body.
        """
        if variant == "plain":
            return self.content
        lines = [self.title] + ([self.heading] if self.heading else [])
        return "\n".join(lines) + "\n\n" + self.content


_FRONTMATTER = re.compile(r"\A---\n(.*?)\n---\n?", re.S)
_HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")
_FENCE = re.compile(r"^\s*(```|~~~)")


def _title(fm: str, body: str, path: Path) -> str:
    m = re.search(r"^title:\s*(.+?)\s*$", fm, re.M)
    if m:
        t = m.group(1).strip().strip("'\"")
        # folded YAML titles continue on indented lines
        cont = re.search(r"^title:.*\n((?:[ \t]+\S.*\n)+)", fm, re.M)
        if cont:
            t += " " + " ".join(s.strip() for s in cont.group(1).splitlines())
            t = t.strip().strip("'\"")
        return t
    m = re.search(r"^#\s+(.+)$", body, re.M)
    return m.group(1).strip() if m else path.stem


def _split_long(text: str) -> list[str]:
    """Cap a section at MAX_CHUNK_CHARS, breaking on blank lines (then hard)."""
    if len(text) <= MAX_CHUNK_CHARS:
        return [text]
    out, cur = [], ""
    for para in re.split(r"(\n\s*\n)", text):
        if len(cur) + len(para) > MAX_CHUNK_CHARS and cur.strip():
            out.append(cur)
            cur = ""
        while len(para) > MAX_CHUNK_CHARS:
            out.append(para[:MAX_CHUNK_CHARS])
            para = para[MAX_CHUNK_CHARS:]
        cur += para
    if cur.strip():
        out.append(cur)
    return out


def load_corpus(root: Path) -> list[Chunk]:
    """Heading-delimited sections of every note, frontmatter stripped."""
    chunks: list[Chunk] = []
    for path in sorted(root.rglob("*.md")):
        rel = path.relative_to(root).as_posix()
        if rel.startswith(".") or "/." in rel:
            continue
        raw = path.read_text(encoding="utf-8", errors="replace")
        fm_m = _FRONTMATTER.match(raw)
        fm, body = (fm_m.group(1), raw[fm_m.end():]) if fm_m else ("", raw)
        title = _title(fm, body, path)

        sections: list[tuple[str | None, list[str]]] = [(None, [])]
        in_fence = False
        for line in body.splitlines():
            if _FENCE.match(line):
                in_fence = not in_fence
            h = None if in_fence else _HEADING.match(line)
            if h:
                sections.append((h.group(2), []))
            else:
                sections[-1][1].append(line)

        first = True
        for heading, lines in sections:
            content = "\n".join(lines)
            if not content.strip():
                continue
            for part in _split_long(content):
                if part.strip():
                    chunks.append(Chunk(rel, title, heading, part, first))
                    first = False
    return chunks


# --------------------------------------------------------------------------- cache


class Cache:
    """Per-model sqlite cache: sha1(text) -> float32 vector. Re-runs are free."""

    def __init__(self, path: Path):
        path.parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(path)
        self.db.execute("create table if not exists v (h text primary key, vec blob)")
        self.db.execute("create table if not exists meta (k text primary key, v text)")

    @staticmethod
    def key(text: str) -> str:
        return hashlib.sha1(text.encode()).hexdigest()

    def get_many(self, texts: list[str]) -> dict[str, np.ndarray]:
        out = {}
        for t in texts:
            row = self.db.execute("select vec from v where h=?", (self.key(t),)).fetchone()
            if row:
                out[t] = np.frombuffer(row[0], dtype=np.float32)
        return out

    def put_many(self, items: dict[str, np.ndarray]) -> None:
        self.db.executemany(
            "insert or replace into v values (?, ?)",
            [(self.key(t), np.asarray(v, dtype=np.float32).tobytes()) for t, v in items.items()],
        )
        self.db.commit()

    def meta_get(self, k: str):
        row = self.db.execute("select v from meta where k=?", (k,)).fetchone()
        return json.loads(row[0]) if row else None

    def meta_put(self, k: str, v) -> None:
        self.db.execute("insert or replace into meta values (?, ?)", (k, json.dumps(v)))
        self.db.commit()


# --------------------------------------------------------------------------- models


class Embedder:
    name: str

    def embed(self, texts: list[str]) -> tuple[list[np.ndarray], dict]:
        raise NotImplementedError


class RemoteEmbedder(Embedder):
    """OpenAI-compatible /embeddings call, exactly the shape the server's
    `openai` provider sends: plain input list, no task type, no dimensions."""

    def __init__(self, kind: str, model: str, api_key: str):
        from openai import OpenAI

        self.name = f"{kind}:{model}"
        self.model = model
        base_url, _ = ENDPOINTS[kind]
        self.client = OpenAI(api_key=api_key, base_url=base_url, timeout=60, max_retries=0)

    def embed(self, texts):
        last = None
        for attempt in range(4):
            try:
                r = self.client.embeddings.create(model=self.model, input=texts)
                # Google's OpenAI-compat layer leaves `index` null; its data is in input order.
                data = r.data if any(d.index is None for d in r.data) else sorted(r.data, key=lambda d: d.index)
                vecs = [np.asarray(d.embedding, dtype=np.float32) for d in data]
                if len(vecs) != len(texts):
                    raise RuntimeError(f"got {len(vecs)} vectors for {len(texts)} inputs")
                u = r.usage
                extra = getattr(u, "model_extra", None) or {}
                return vecs, {
                    "tokens": getattr(u, "prompt_tokens", 0) or 0,
                    "cost": float(extra.get("cost") or 0.0),
                }
            except Exception as e:  # noqa: BLE001 — report and retry any transport/API error
                last = e
                time.sleep(2 * (attempt + 1))
        raise RuntimeError(f"{self.name}: {last}") from last


class LocalEmbedder(Embedder):
    """fastembed on this machine — the same library the deployed server uses."""

    def __init__(self, model: str, cache_dir: Path):
        from fastembed import TextEmbedding

        self.name = f"local:{model}"
        self.model = TextEmbedding(model_name=model, cache_dir=str(cache_dir))

    def embed(self, texts):
        return [np.asarray(v, dtype=np.float32) for v in self.model.embed(texts)], {"tokens": 0, "cost": 0.0}


def make_embedder(spec: str, data: Path) -> Embedder:
    kind, _, model = spec.partition(":")
    if kind in ENDPOINTS:
        env = ENDPOINTS[kind][1]
        key = os.environ.get(env)
        if not key:
            raise RuntimeError(f"{env} is not set (put it in bench/.env)")
        return RemoteEmbedder(kind, model, key)
    if kind == "local":
        return LocalEmbedder(model, data / "fastembed")
    sys.exit(f"unknown model spec {spec!r}: use or:<id>, gai:<id> or local:<fastembed-id>")


def slug(spec: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]+", "_", spec)


def embed_cached(emb: Embedder, cache: Cache, texts: list[str]) -> tuple[np.ndarray, dict]:
    """Vectors for texts (L2-normalised), embedding only the cache misses."""
    have = cache.get_many(list(dict.fromkeys(texts)))
    missing = [t for t in dict.fromkeys(texts) if t not in have]
    stats = {"embedded": len(missing), "tokens": 0, "cost": 0.0, "seconds": 0.0}
    t0 = time.perf_counter()
    for i in range(0, len(missing), BATCH):
        batch = missing[i : i + BATCH]
        vecs, u = emb.embed(batch)
        stats["tokens"] += u["tokens"]
        stats["cost"] += u["cost"]
        new = dict(zip(batch, vecs))
        cache.put_many(new)
        have.update(new)
        print(f"    {min(i + BATCH, len(missing))}/{len(missing)}", end="\r", flush=True)
    stats["seconds"] = time.perf_counter() - t0
    m = np.stack([have[t] for t in texts])
    m /= np.linalg.norm(m, axis=1, keepdims=True) + 1e-12
    return m, stats


# --------------------------------------------------------------------------- eval


def evaluate(chunks: list[Chunk], doc_m: np.ndarray, q_m: np.ndarray, queries: list[dict]):
    paths = sorted({c.path for c in chunks})
    pidx = {p: i for i, p in enumerate(paths)}
    owner = np.array([pidx[c.path] for c in chunks])
    sims = q_m @ doc_m.T  # (queries, chunks)
    per_q = []
    for qi, q in enumerate(queries):
        doc_scores = np.full(len(paths), -1.0)
        np.maximum.at(doc_scores, owner, sims[qi])
        order = np.argsort(-doc_scores)
        ranks = [int(np.where(order == pidx[p])[0][0]) + 1 for p in q["relevant"] if p in pidx]
        best = min(ranks) if ranks else None
        per_q.append({
            "q": q["q"],
            "rank": best,
            "top3": [[paths[i], round(float(doc_scores[i]), 4)] for i in order[:3]],
        })
    rs = [r["rank"] for r in per_q]
    return {
        "R@1": sum(1 for r in rs if r and r <= 1) / len(rs),
        "R@5": sum(1 for r in rs if r and r <= 5) / len(rs),
        "MRR@10": sum(1 / r for r in rs if r and r <= 10) / len(rs),
    }, per_q


def latency(emb: Embedder, queries: list[dict], n: int) -> dict:
    """Uncached single-query calls, sequential — what one vault search pays."""
    times = []
    for i in range(n):
        q = queries[i % len(queries)]["q"] + f" #{i}"  # defeat any upstream cache
        t0 = time.perf_counter()
        emb.embed([q])
        times.append((time.perf_counter() - t0) * 1000)
    times.sort()
    return {"p50_ms": statistics.median(times), "p95_ms": times[max(0, int(round(0.95 * n)) - 1)]}


# --------------------------------------------------------------------------- main


def load_env(path: Path) -> None:
    if not path.exists():
        return
    for line in path.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            os.environ.setdefault(k.strip(), v.strip().strip("'\""))


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--corpus", type=Path, required=True, help="folder of .md notes")
    ap.add_argument("--queries", type=Path, required=True, help="JSON list of {q, relevant}")
    ap.add_argument("--models", default=",".join(DEFAULT_MODELS), help="comma-separated or:<id> / local:<id>")
    ap.add_argument("--variants", default="plain,ctx", help="plain (server default) and/or ctx (EMBED_CONTEXT)")
    ap.add_argument("--latency-n", type=int, default=20, help="single-query calls per model (0 = skip)")
    ap.add_argument("--latency-only", action="store_true",
                    help="skip the corpus and quality eval; only time single-query calls")
    ap.add_argument("--data", type=Path, default=HERE / ".data", help="cache + results dir (gitignored)")
    args = ap.parse_args()

    load_env(HERE / ".env")
    variants = [v for v in args.variants.split(",") if v]
    assert all(v in VARIANTS for v in variants), f"variants must be among {VARIANTS}"

    chunks = load_corpus(args.corpus)
    queries = json.loads(args.queries.read_text())
    known = {c.path for c in chunks}
    for q in queries:
        bad = [p for p in q["relevant"] if p not in known]
        if bad:
            sys.exit(f"query {q['q']!r}: relevant path(s) not in corpus: {bad}")
    print(f"corpus: {len(known)} notes, {len(chunks)} chunks, "
          f"{sum(len(c.content) for c in chunks):,} chars · {len(queries)} queries\n")

    run_dir = args.data / "results" / time.strftime("%Y%m%d-%H%M%S")
    run_dir.mkdir(parents=True, exist_ok=True)
    rows, full = [], {}
    for spec in [m for m in args.models.split(",") if m]:
        print(f"== {spec}")
        try:
            emb = make_embedder(spec, args.data)
            if args.latency_only:
                lat = latency(emb, queries, args.latency_n or 20)
                print(f"   latency p50 {lat['p50_ms']:.0f} ms · p95 {lat['p95_ms']:.0f} ms\n")
                rows.append({"model": spec, "latency_only": True, **lat})
                continue
            cache = Cache(args.data / "cache" / f"{slug(spec)}.sqlite")
            q_m, _ = embed_cached(emb, cache, [q["q"] for q in queries])
            lat = latency(emb, queries, args.latency_n) if args.latency_n else {}
        except Exception as e:  # noqa: BLE001 — one broken model must not sink the run
            print(f"   FAILED: {e}\n")
            rows.append({"model": spec, "error": str(e)[:200]})
            continue
        for variant in variants:
            try:
                doc_m, st = embed_cached(emb, cache, [c.text(variant) for c in chunks])
            except Exception as e:  # noqa: BLE001
                print(f"   {variant}: FAILED: {e}")
                rows.append({"model": spec, "variant": variant, "error": str(e)[:200]})
                continue
            # Remember the cost of a full (uncached) corpus pass for later re-runs.
            if st["embedded"] == len(set(c.text(variant) for c in chunks)):
                cache.meta_put(f"full:{variant}", st)
            full_st = cache.meta_get(f"full:{variant}") or {}
            metrics, per_q = evaluate(chunks, doc_m, q_m, queries)
            row = {"model": spec, "variant": variant, "dim": int(doc_m.shape[1]), **metrics, **lat,
                   "corpus_s": full_st.get("seconds"), "tokens": full_st.get("tokens"),
                   "cost_usd": full_st.get("cost")}
            rows.append(row)
            full[f"{spec}|{variant}"] = per_q
            print(f"   {variant:5}  R@1 {metrics['R@1']:.2f}  R@5 {metrics['R@5']:.2f}  "
                  f"MRR {metrics['MRR@10']:.3f}  dim {row['dim']}")
        if lat:
            print(f"   latency p50 {lat['p50_ms']:.0f} ms · p95 {lat['p95_ms']:.0f} ms")
        print()

    (run_dir / "summary.json").write_text(json.dumps(rows, ensure_ascii=False, indent=2))
    (run_dir / "per_query.json").write_text(json.dumps(full, ensure_ascii=False, indent=2))

    lat_rows = [r for r in rows if r.get("latency_only")]
    if lat_rows:
        print(f"{'model':45} {'p50ms':>6} {'p95ms':>6}\n" + "-" * 59)
        for r in sorted(lat_rows, key=lambda r: r["p50_ms"]):
            print(f"{r['model']:45} {r['p50_ms']:6.0f} {r['p95_ms']:6.0f}")
    ok = sorted((r for r in rows if "error" not in r and not r.get("latency_only")),
                key=lambda r: (-r["MRR@10"], -r["R@5"]))
    hdr = f"{'model':58} {'var':5} {'R@1':>5} {'R@5':>5} {'MRR':>6} {'dim':>5} {'p50ms':>6} {'p95ms':>6} {'corpus_s':>8} {'tokens':>7} {'$':>7}"
    print(hdr + "\n" + "-" * len(hdr))
    for r in ok:
        f = lambda v, fmt: (fmt.format(v) if isinstance(v, (int, float)) else "—")  # noqa: E731
        print(f"{r['model']:58} {r['variant']:5} {r['R@1']:5.2f} {r['R@5']:5.2f} {r['MRR@10']:6.3f} "
              f"{r['dim']:5} {f(r.get('p50_ms'), '{:6.0f}'):>6} {f(r.get('p95_ms'), '{:6.0f}'):>6} "
              f"{f(r.get('corpus_s'), '{:8.1f}'):>8} {f(r.get('tokens'), '{:7d}'):>7} {f(r.get('cost_usd'), '{:7.4f}'):>7}")
    for r in rows:
        if "error" in r:
            print(f"{r['model']:58} {r.get('variant', ''):5} ERROR {r['error']}")
    print(f"\nper-query detail: {run_dir}")


if __name__ == "__main__":
    main()
