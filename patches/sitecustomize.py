"""Startup patch for markdown-vault-mcp: tolerate a missing `index` in embeddings.

Python imports `sitecustomize` automatically at interpreter start when it is on
`sys.path`. docker-compose.yml mounts this directory read-only and puts it on
PYTHONPATH, so the patch applies without forking or rebuilding the image.

Why: Gemini's OpenAI-compatibility endpoint serialises its response from
protobuf, which drops default values, so the first embedding arrives with no
`index` field (None after openai-SDK parsing) and the rest as 1, 2, ...
markdown-vault-mcp sorts the batch by `index` (providers.py,
`sorted(response.data, key=lambda d: d.index)`), and comparing None with an int
raises TypeError on any batch of two or more texts, so indexing fails.

What: wrap `openai.resources.embeddings.Embeddings.create` and fill a missing
`index` with the item's position in the response, which is the input order.
Responses that already carry every index are left untouched, so this is a no-op
for OpenAI, OpenRouter and Ollama, and becomes a no-op everywhere once the
upstream fix lands (pvliesdonk/markdown-vault-mcp, sort with `index or 0`).
Then delete this file and its mount.

Any failure here is swallowed: a broken patch must never stop the server from
starting.
"""

import functools


def _install() -> None:
    from openai.resources.embeddings import Embeddings

    if getattr(Embeddings.create, "_ram_index_patch", False):
        return
    original = Embeddings.create

    @functools.wraps(original)
    def create(self, *args, **kwargs):
        response = original(self, *args, **kwargs)
        for position, item in enumerate(getattr(response, "data", None) or []):
            if getattr(item, "index", 0) is None:
                item.index = position
        return response

    create._ram_index_patch = True
    Embeddings.create = create


try:
    _install()
except Exception:  # noqa: BLE001 — never block interpreter startup
    pass
