# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2026 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""What every PDF download shares: the sniffed prefix, the partial file, the limit.

Split from ``pdf_discovery`` so a client that downloads a PDF itself (Elsevier's
Article API, #480 stage C2) can use the same rules without importing the
discovery, which in turn imports that client. ``pdf_discovery`` re-exports
every name here, so its existing imports keep working.
"""

from __future__ import annotations

import logging
from collections.abc import Iterator
from pathlib import Path

from .constants import PDF_PARTIAL_SUFFIX

logger = logging.getLogger(__name__)

# Maximum PDF file size (100 MB)
MAX_PDF_SIZE = 100 * 1024 * 1024


def read_body_prefix(chunks: Iterator[bytes], at_least: int) -> bytes:
    """Read the start of a streamed body, enough of it to sniff.

    A first chunk can be shorter than the bytes a sniff needs -- one HTTP
    chunk of a chunked body -- so chunks are joined until there are enough
    or the body ends. A read that fails raises: it is the transport's
    failure, not an empty body.

    Args:
        chunks: The body's chunks, consumed as far as needed.
        at_least: How many bytes the caller needs.

    Returns:
        The bytes read, which are ``at_least`` or more unless the body was
        shorter.
    """
    prefix = b""
    for chunk in chunks:
        prefix += chunk
        if len(prefix) >= at_least:
            break
    return prefix


def partial_download_path(output_path: Path) -> Path:
    """Where a PDF is written while its download is in progress.

    Args:
        output_path: Where the PDF is to end up.

    Returns:
        ``output_path`` with :data:`PDF_PARTIAL_SUFFIX` appended, beside it,
        so the rename into place stays on one filesystem.
    """
    return output_path.with_name(output_path.name + PDF_PARTIAL_SUFFIX)


def discard_partial_download(partial: Path) -> None:
    """Remove a partial download, if one is left.

    Logged rather than raised when it cannot be removed: the download's own
    outcome is what the caller reports, and a leftover partial file is never
    read as the PDF -- only the renamed file is.

    Args:
        partial: The partial file; may not exist.
    """
    try:
        partial.unlink(missing_ok=True)
    except OSError as e:
        logger.warning("Could not remove the partial download %s: %s", partial, e)
