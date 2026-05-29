#!/usr/bin/env python3
"""Purge Cloudflare cache entries for deployed web exports."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
from typing import Iterable
from urllib import error, parse, request


TRUTHY_VALUES = {"1", "true", "yes", "on"}


def is_truthy(value: str | None) -> bool:
    if value is None:
        return False
    return value.strip().lower() in TRUTHY_VALUES


def normalize_base_url(base_url: str) -> str:
    normalized = base_url.strip().rstrip("/")
    if not normalized.startswith(("http://", "https://")):
        raise ValueError("base URL must start with http:// or https://")
    return normalized


def build_purge_urls(base_url: str, export_dir: Path) -> list[str]:
    normalized_base_url = normalize_base_url(base_url)
    urls: list[str] = [normalized_base_url + "/"]

    for path in sorted(export_dir.iterdir()):
        if not path.is_file():
            continue
        if path.suffix == ".import":
            continue
        urls.append(normalized_base_url + "/" + parse.quote(path.name))

    deduped: list[str] = []
    seen: set[str] = set()
    for url in urls:
        if url in seen:
            continue
        seen.add(url)
        deduped.append(url)
    return deduped


def purge_cloudflare_cache(
    zone_id: str,
    api_token: str,
    urls: Iterable[str],
    purge_everything: bool = False,
    endpoint_root: str = "https://api.cloudflare.com/client/v4",
) -> dict:
    normalized_endpoint_root = endpoint_root.rstrip("/")
    endpoint = f"{normalized_endpoint_root}/zones/{zone_id}/purge_cache"
    payload: dict[str, object]
    if purge_everything:
        payload = {"purge_everything": True}
    else:
        file_urls = list(urls)
        if not file_urls:
            raise ValueError("at least one URL is required when purge_everything is false")
        payload = {"files": file_urls}

    req = request.Request(
        endpoint,
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {api_token}",
            "Content-Type": "application/json",
        },
        method="POST",
    )

    try:
        with request.urlopen(req, timeout=30) as response:
            body = response.read().decode("utf-8")
    except error.HTTPError as exc:
        details = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"Cloudflare purge failed with HTTP {exc.code}: {details}") from exc
    except error.URLError as exc:
        raise RuntimeError(f"Cloudflare purge request failed: {exc}") from exc

    data = json.loads(body)
    if not data.get("success"):
        raise RuntimeError(f"Cloudflare purge was rejected: {data}")
    return data


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zone-id", default=os.environ.get("CLOUDFLARE_ZONE_ID", ""))
    parser.add_argument("--api-token", default=os.environ.get("CLOUDFLARE_API_TOKEN", ""))
    parser.add_argument("--base-url", default=os.environ.get("CLOUDFLARE_BASE_URL", ""))
    parser.add_argument("--export-dir", default="")
    parser.add_argument("--file-url", action="append", default=[])
    parser.add_argument("--purge-everything", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument(
        "--endpoint-root",
        default=os.environ.get("CLOUDFLARE_API_ROOT", "https://api.cloudflare.com/client/v4"),
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    purge_everything = args.purge_everything or is_truthy(os.environ.get("CLOUDFLARE_PURGE_EVERYTHING"))

    urls = list(args.file_url)
    if args.export_dir:
        export_dir = Path(args.export_dir)
        if not export_dir.is_dir():
            raise SystemExit(f"export directory does not exist: {export_dir}")
        if not args.base_url:
            raise SystemExit("--base-url is required when --export-dir is used")
        urls.extend(build_purge_urls(args.base_url, export_dir))

    if not purge_everything and not urls:
        raise SystemExit("provide --export-dir, --file-url, or set --purge-everything")
    if not args.zone_id:
        raise SystemExit("missing Cloudflare zone id (set --zone-id or CLOUDFLARE_ZONE_ID)")
    if not args.api_token:
        raise SystemExit("missing Cloudflare API token (set --api-token or CLOUDFLARE_API_TOKEN)")

    if args.dry_run:
        if purge_everything:
            print("Would purge everything")
        else:
            print(json.dumps({"files": urls}, ensure_ascii=False, indent=2))
        return 0

    response = purge_cloudflare_cache(
        zone_id=args.zone_id,
        api_token=args.api_token,
        urls=urls,
        purge_everything=purge_everything,
        endpoint_root=args.endpoint_root,
    )
    print(json.dumps(response, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())