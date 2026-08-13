#!/usr/bin/env python3
"""Generate a Swift file manifest for a Hugging Face MLX model snapshot.

The local MLX enhancement path pins every model to an exact revision and
verifies each downloaded file by size and SHA-256. This script produces the
`LocalMLXModelFile` entries for a repository so a new model can be added
without hand-transcribing hashes.

LFS blobs expose their SHA-256 through the Hub `paths-info` API. Plain git
blobs only expose a SHA-1 object id, so those files are fetched and hashed
locally; they are small (configs, tokenizer settings, chat templates).

Usage:
    scripts/generate-mlx-model-manifest.py mlx-community/gemma-4-e2b-it-4bit
    scripts/generate-mlx-model-manifest.py <repo> --revision <sha>
"""

import argparse
import hashlib
import json
import sys
import urllib.request

HUB = "https://huggingface.co"
# Files that exist in a repository but are never needed to load the model.
SKIPPED_FILES = {".gitattributes", "README.md"}


def fetch_json(url, payload=None):
    request = urllib.request.Request(url)
    data = None
    if payload is not None:
        request.add_header("Content-Type", "application/json")
        data = json.dumps(payload).encode()
    with urllib.request.urlopen(request, data) as response:
        return json.load(response)


def fetch_bytes(repo, revision, path):
    url = f"{HUB}/{repo}/resolve/{revision}/{path}"
    with urllib.request.urlopen(url) as response:
        return response.read()


def build_manifest(repo, revision):
    info = fetch_json(f"{HUB}/api/models/{repo}")
    revision = revision or info["sha"]

    paths = sorted(
        sibling["rfilename"]
        for sibling in info["siblings"]
        if sibling["rfilename"] not in SKIPPED_FILES
    )
    entries = fetch_json(
        f"{HUB}/api/models/{repo}/paths-info/{revision}",
        {"paths": paths, "expand": True},
    )

    manifest = []
    for entry in sorted(entries, key=lambda item: item["path"]):
        path = entry["path"]
        size = entry.get("size", 0)
        lfs = entry.get("lfs") or {}
        digest = lfs.get("oid")
        if not digest:
            # Plain git blob: hash the bytes ourselves.
            digest = hashlib.sha256(fetch_bytes(repo, revision, path)).hexdigest()
        manifest.append((path, size, digest))
    return revision, manifest


def render_swift(repo, revision, manifest):
    total = sum(size for _, size, _ in manifest)
    lines = [
        f"// {repo}",
        f"// revision {revision}",
        f"// {len(manifest)} files, {total:,} bytes ({total / 1e9:.2f} GB)",
        "files: [",
    ]
    for path, size, digest in manifest:
        lines.append("    LocalMLXModelFile(")
        lines.append(f'        path: "{path}",')
        lines.append(f"        size: {size:_},")
        lines.append(f'        sha256: "{digest}"')
        lines.append("    ),")
    lines.append("]")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repository", help="Hugging Face repo id, e.g. mlx-community/gemma-4-e2b-it-4bit")
    parser.add_argument("--revision", help="Pin to this commit sha instead of the current head")
    arguments = parser.parse_args()

    try:
        revision, manifest = build_manifest(arguments.repository, arguments.revision)
    except urllib.error.HTTPError as error:
        print(f"error: {arguments.repository}: {error}", file=sys.stderr)
        return 1

    print(render_swift(arguments.repository, revision, manifest))
    return 0


if __name__ == "__main__":
    sys.exit(main())
