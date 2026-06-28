#!/usr/bin/env python3
"""Run concurrent chat/completions load and report client-side latencies."""
from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, as_completed, wait
from typing import Any


def percentile(values: list[float], p: float) -> float:
    if not values:
        return float("nan")
    ordered = sorted(values)
    idx = max(0, int(len(ordered) * p) - 1)
    return ordered[idx]


def one_request(
    url: str,
    model: str,
    headers: dict[str, str],
    stream: bool,
    max_tokens: int,
    prompt: str,
    timeout: float,
) -> dict[str, Any]:
    body = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "stream": stream,
    }
    data = json.dumps(body).encode()
    req = urllib.request.Request(
        url,
        data=data,
        headers={**headers, "Content-Type": "application/json"},
        method="POST",
    )
    start = time.perf_counter()
    ttft_ms: float | None = None
    status = 0
    err = ""
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            status = resp.status
            if stream:
                for raw in resp:
                    line = raw.decode("utf-8", errors="replace").strip()
                    if not line.startswith("data:"):
                        continue
                    payload = line[5:].strip()
                    if payload == "[DONE]":
                        break
                    if ttft_ms is None and payload:
                        ttft_ms = (time.perf_counter() - start) * 1000.0
            else:
                resp.read()
    except urllib.error.HTTPError as exc:
        status = exc.code
        err = exc.reason or "http_error"
    except Exception as exc:  # noqa: BLE001
        status = 0
        err = str(exc)
    e2e_ms = (time.perf_counter() - start) * 1000.0
    if ttft_ms is None and status == 200:
        ttft_ms = e2e_ms
    return {
        "status": status,
        "ttft_ms": ttft_ms,
        "e2e_ms": e2e_ms,
        "error": err,
    }


def run_load(
    url: str,
    model: str,
    headers: dict[str, str],
    *,
    requests: int,
    concurrency: int,
    stream: bool,
    duration_sec: int,
    max_tokens: int,
    prompt: str,
    timeout: float,
) -> dict[str, Any]:
    results: list[dict[str, Any]] = []
    submitted = 0

    def worker() -> dict[str, Any]:
        return one_request(url, model, headers, stream, max_tokens, prompt, timeout)

    with ThreadPoolExecutor(max_workers=max(1, concurrency)) as pool:
        if duration_sec > 0:
            end = time.time() + duration_sec
            futures = set()
            while time.time() < end or futures:
                while len(futures) < concurrency and time.time() < end:
                    futures.add(pool.submit(worker))
                    submitted += 1
                if not futures:
                    break
                done, futures = wait(futures, timeout=1.0, return_when=FIRST_COMPLETED)
                for fut in done:
                    results.append(fut.result())
        else:
            futures = [pool.submit(worker) for _ in range(requests)]
            submitted = requests
            for fut in as_completed(futures):
                results.append(fut.result())

    ok = [r for r in results if r["status"] == 200]
    fail = [r for r in results if r["status"] != 200]
    ttft = [float(r["ttft_ms"]) for r in ok if r["ttft_ms"] is not None]
    e2e = [float(r["e2e_ms"]) for r in ok]
    total = len(results) or 1
    out = {
        "submitted": submitted,
        "completed": len(results),
        "success": len(ok),
        "fail": len(fail),
        "error_rate": len(fail) / total,
        "ttft_p50_ms": percentile(ttft, 0.50) if ttft else None,
        "ttft_p95_ms": percentile(ttft, 0.95) if ttft else None,
        "e2e_p50_ms": percentile(e2e, 0.50) if e2e else None,
        "e2e_p95_ms": percentile(e2e, 0.95) if e2e else None,
        "stream": stream,
    }
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description="vLLM load test runner")
    parser.add_argument("--url", required=True, help="Full chat/completions URL")
    parser.add_argument("--model", required=True)
    parser.add_argument("--header", action="append", default=[], help="Header as Name:Value")
    parser.add_argument("--requests", type=int, default=20)
    parser.add_argument("--concurrency", type=int, default=4)
    parser.add_argument("--duration-sec", type=int, default=0, help="If >0, run until duration")
    parser.add_argument("--stream", action="store_true", default=True)
    parser.add_argument("--no-stream", dest="stream", action="store_false")
    parser.add_argument("--max-tokens", type=int, default=32)
    parser.add_argument(
        "--prompt",
        default="Write a short paragraph about autoscaling on Kubernetes.",
    )
    parser.add_argument("--timeout", type=float, default=120.0)
    args = parser.parse_args()

    headers: dict[str, str] = {}
    for item in args.header:
        name, _, value = item.partition(":")
        headers[name.strip()] = value.strip()

    stats = run_load(
        args.url,
        args.model,
        headers,
        requests=args.requests,
        concurrency=args.concurrency,
        stream=args.stream,
        duration_sec=args.duration_sec,
        max_tokens=args.max_tokens,
        prompt=args.prompt,
        timeout=args.timeout,
    )
    json.dump(stats, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
