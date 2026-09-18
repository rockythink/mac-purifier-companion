#!/usr/bin/env python3
"""Fetch the exact source archives needed to reproduce the bundled runtime deps."""

from __future__ import annotations

import hashlib
from pathlib import Path
import sys
import tomllib
from urllib.request import Request, urlopen
from urllib.parse import urlparse

CPYTHON = {
    "url": "https://www.python.org/ftp/python/3.12.12/Python-3.12.12.tgz",
    "sha256": "487c908ddf4097a1b9ba859f25fe46d22ccaabfb335880faac305ac62bffb79b",
}
PYTHON_BUILD_STANDALONE = {
    "url": "https://github.com/astral-sh/python-build-standalone/archive/refs/tags/20260211.tar.gz",
    "sha256": "a70d814140fb061d5724c477aeecfdf263e890d3a3515546763adc727f929628",
}
MACMON = {
    "url": "https://github.com/vladkens/macmon/archive/refs/tags/v0.8.2.tar.gz",
    "sha256": "f613c7e1b395a68e696b8f2ed82a0157cae87215b91e429e15c98f5a9662076a",
}


def download(url: str, expected_sha256: str, destination: Path) -> None:
    if destination.is_file():
        actual = hashlib.sha256(destination.read_bytes()).hexdigest()
        if actual == expected_sha256:
            return
        destination.unlink()

    temporary = destination.with_suffix(destination.suffix + ".partial")
    temporary.unlink(missing_ok=True)
    digest = hashlib.sha256()
    request = Request(url, headers={"User-Agent": "MacFanLink source packager/1.0"})
    with urlopen(request, timeout=120) as response, temporary.open("wb") as output:
        while chunk := response.read(1024 * 1024):
            output.write(chunk)
            digest.update(chunk)
    actual = digest.hexdigest()
    if actual != expected_sha256:
        temporary.unlink(missing_ok=True)
        raise RuntimeError(f"SHA-256 mismatch for {url}: {actual}")
    temporary.replace(destination)


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    lock_path = root / "uv.lock"
    output = root / "dist" / "source-dependencies" / "python"
    output.mkdir(parents=True, exist_ok=True)
    macmon_output = root / "dist" / "source-dependencies" / "macmon"
    macmon_output.mkdir(parents=True, exist_ok=True)

    lock = tomllib.loads(lock_path.read_text(encoding="utf-8"))
    records: list[tuple[str, str, str]] = []
    for package in lock["package"]:
        source = package.get("source", {})
        if "registry" not in source:
            continue
        sdist = package.get("sdist")
        if not sdist:
            raise RuntimeError(
                f"locked registry package has no source archive: "
                f"{package['name']}=={package['version']}"
            )
        algorithm, expected = sdist["hash"].split(":", 1)
        if algorithm != "sha256":
            raise RuntimeError(f"unsupported source hash: {sdist['hash']}")
        filename = Path(urlparse(sdist["url"]).path).name
        download(sdist["url"], expected, output / filename)
        records.append((filename, expected, f"{package['name']}=={package['version']}"))

    cpython_name = Path(urlparse(CPYTHON["url"]).path).name
    download(CPYTHON["url"], CPYTHON["sha256"], output / cpython_name)
    records.append((cpython_name, CPYTHON["sha256"], "CPython==3.12.12"))
    builder_name = "python-build-standalone-20260211.tar.gz"
    download(
        PYTHON_BUILD_STANDALONE["url"],
        PYTHON_BUILD_STANDALONE["sha256"],
        output / builder_name,
    )
    records.append(
        (
            builder_name,
            PYTHON_BUILD_STANDALONE["sha256"],
            "python-build-standalone==20260211",
        )
    )
    macmon_name = "macmon-0.8.2.tar.gz"
    download(MACMON["url"], MACMON["sha256"], macmon_output / macmon_name)
    (macmon_output / "SHA256SUMS").write_text(
        f"{MACMON['sha256']}  {macmon_name}\n",
        encoding="utf-8",
    )

    manifest = output / "SHA256SUMS"
    manifest.write_text(
        "".join(f"{digest}  {filename}\n" for filename, digest, _ in sorted(records)),
        encoding="utf-8",
    )
    print(f"Prepared {len(records)} verified source archives in {output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
