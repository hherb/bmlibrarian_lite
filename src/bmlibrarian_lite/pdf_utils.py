# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.

"""
PDF and full-text utility functions for BMLibrarian Lite.

Pure functions for PDF/full-text file path management and document formatting:
- get_pdf_base_dir(): Get the base directory for PDF storage
- get_fulltext_base_dir(): Get the base directory for full-text markdown storage
- generate_pdf_path(): Generate standard PDF path for a document
- generate_fulltext_path(): Generate standard full-text markdown path for a document
- find_existing_pdf(): Check if a PDF already exists locally
- find_existing_fulltext(): Check if a full-text markdown already exists locally
- fulltext_cache_stamp(): The first line naming the converter that wrote a cached file
- save_fulltext_markdown(): Cache converted markdown, stamped with its converter
- read_cached_fulltext(): Read cached markdown, or None if an older converter wrote it
- read_stale_cached_fulltext(): Read cached markdown whichever converter wrote it
- format_abstract_as_document(): Format abstract and citation as readable document
- extract_pdf_text(): Extract text from a PDF file

These functions are stateless and can be reused across different modules.

Usage:
    from bmlibrarian_lite.pdf_utils import (
        get_pdf_base_dir,
        get_fulltext_base_dir,
        generate_pdf_path,
        generate_fulltext_path,
        find_existing_pdf,
        find_existing_fulltext,
        format_abstract_as_document,
    )

    # Get PDF storage directory
    base_dir = get_pdf_base_dir()

    # Generate path for a document
    doc = {'doi': '10.1038/nature12373', 'year': 2023}
    pdf_path = generate_pdf_path(doc, base_dir)

    # Check for existing PDF
    existing = find_existing_pdf(doc, base_dir)

    # Check for existing full-text markdown (from Europe PMC XML), and read
    # it only through read_cached_fulltext, which checks and strips its stamp
    path = find_existing_fulltext(doc)
    markdown = read_cached_fulltext(path) if path else None
"""

import logging
import os
from pathlib import Path
from typing import Any, Dict, Optional

from .constants import (
    DEFAULT_FULLTEXT_BASE_DIR,
    DEFAULT_PDF_BASE_DIR,
    PDF_BASE_DIR_ENV_VAR,
)
from .jats_markdown import JATS_MARKDOWN_CONVERTER_VERSION

logger = logging.getLogger(__name__)


def get_pdf_base_dir(env_var: str = PDF_BASE_DIR_ENV_VAR) -> Path:
    """
    Get the base directory for PDF storage.

    Uses PDF_BASE_DIR environment variable or defaults to ~/knowledgebase/pdf.

    Args:
        env_var: Environment variable name to check (default: PDF_BASE_DIR)

    Returns:
        Path to PDF base directory (expanded user path)

    Example:
        base_dir = get_pdf_base_dir()
        # Returns Path("/home/user/knowledgebase/pdf") or custom path from env
    """
    pdf_base = os.environ.get(env_var)
    if pdf_base:
        return Path(pdf_base).expanduser()
    return Path.home() / DEFAULT_PDF_BASE_DIR


def get_fulltext_base_dir() -> Path:
    """
    Get the base directory for full-text markdown storage.

    Full-text markdown files are generated from JATS XML (Europe PMC's, or
    PMC's open-data bucket's) and cached for faster subsequent access.

    Returns:
        Path to full-text markdown base directory

    Example:
        base_dir = get_fulltext_base_dir()
        # Returns Path("/home/user/knowledgebase/fulltext")
    """
    return Path.home() / DEFAULT_FULLTEXT_BASE_DIR


def generate_pdf_path(
    doc_dict: Dict[str, Any],
    base_dir: Optional[Path] = None,
) -> Path:
    """
    Generate the standard PDF path for a document.

    Uses year-based folder structure with DOI-based or ID-based filename.
    Structure: {base_dir}/{year}/{filename}.pdf

    Args:
        doc_dict: Document dictionary with doi, year, id, publication_date, etc.
        base_dir: Base directory for PDF storage (default: from get_pdf_base_dir())

    Returns:
        Path where PDF should be stored

    Example:
        doc = {'doi': '10.1038/nature12373', 'year': 2023}
        path = generate_pdf_path(doc)
        # Returns Path("~/knowledgebase/pdf/2023/10.1038_nature12373.pdf")
    """
    if base_dir is None:
        base_dir = get_pdf_base_dir()

    # Extract year for subdirectory
    year = _extract_year(doc_dict)
    year_dir = str(year) if year else 'unknown'
    output_dir = base_dir / year_dir
    output_dir.mkdir(parents=True, exist_ok=True)

    # Generate filename from DOI or document ID
    doi = doc_dict.get('doi')
    if doi:
        # DOI-based filename (replace slashes)
        safe_doi = doi.replace('/', '_').replace('\\', '_')
        filename = f"{safe_doi}.pdf"
    else:
        # Document ID-based filename
        doc_id = doc_dict.get('id', 'unknown')
        filename = f"doc_{doc_id}.pdf"

    return output_dir / filename


def _extract_year(doc_dict: Dict[str, Any]) -> Optional[int]:
    """
    Extract year from document dictionary.

    Checks 'year' field first, then tries to parse from 'publication_date'.

    Args:
        doc_dict: Document dictionary

    Returns:
        Year as integer or None if not found/parseable
    """
    year = doc_dict.get('year')
    if year:
        return int(year) if isinstance(year, (int, str)) else None

    pub_date = doc_dict.get('publication_date')
    if pub_date and isinstance(pub_date, str) and len(pub_date) >= 4:
        try:
            return int(pub_date[:4])
        except ValueError:
            pass

    return None


def find_existing_pdf(
    doc_dict: Dict[str, Any],
    base_dir: Optional[Path] = None,
) -> Optional[Path]:
    """
    Check if a PDF already exists locally for this document.

    Searches both the expected path and year-based subdirectories
    to find existing PDFs that may have been stored previously.

    Args:
        doc_dict: Document dictionary with doi, year, id, etc.
        base_dir: Base directory for PDF storage (default: from get_pdf_base_dir())

    Returns:
        Path to existing PDF if found, None otherwise

    Example:
        doc = {'doi': '10.1038/nature12373', 'year': 2023}
        existing = find_existing_pdf(doc)
        if existing:
            print(f"Found PDF at: {existing}")
    """
    if base_dir is None:
        base_dir = get_pdf_base_dir()

    # First check expected path
    expected_path = generate_pdf_path(doc_dict, base_dir)
    if expected_path.exists():
        logger.info(f"Found existing PDF at: {expected_path}")
        return expected_path

    # Also check by DOI in all year directories
    doi = doc_dict.get('doi')
    if doi:
        safe_doi = doi.replace('/', '_').replace('\\', '_')
        filename = f"{safe_doi}.pdf"

        # Search all year directories
        if base_dir.exists():
            for year_dir in base_dir.iterdir():
                if year_dir.is_dir():
                    pdf_path = year_dir / filename
                    if pdf_path.exists():
                        logger.info(f"Found existing PDF at: {pdf_path}")
                        return pdf_path

    return None


def generate_fulltext_path(
    doc_dict: Dict[str, Any],
    base_dir: Optional[Path] = None,
) -> Path:
    """
    Generate the standard full-text markdown path for a document.

    Uses year-based folder structure with identifier-based filename.
    Structure: {base_dir}/{year}/{filename}.md

    Args:
        doc_dict: Document dictionary with pmcid, pmid, doi, year, id, etc.
        base_dir: Base directory for full-text storage (default: from get_fulltext_base_dir())

    Returns:
        Path where full-text markdown should be stored

    Example:
        doc = {'pmcid': 'PMC12101959', 'year': 2024}
        path = generate_fulltext_path(doc)
        # Returns Path("~/knowledgebase/fulltext/2024/PMC12101959.md")
    """
    if base_dir is None:
        base_dir = get_fulltext_base_dir()

    # Extract year for subdirectory
    year = _extract_year(doc_dict)
    year_dir = str(year) if year else 'unknown'
    output_dir = base_dir / year_dir
    output_dir.mkdir(parents=True, exist_ok=True)

    # Generate filename - prefer PMC ID, then PMID, then DOI
    pmcid = doc_dict.get('pmcid') or doc_dict.get('pmc_id')
    if pmcid:
        # Normalize PMC ID
        pmc_num = pmcid.replace("PMC", "")
        filename = f"PMC{pmc_num}.md"
    elif doc_dict.get('pmid'):
        filename = f"pmid_{doc_dict['pmid']}.md"
    elif doc_dict.get('doi'):
        safe_doi = doc_dict['doi'].replace('/', '_').replace('\\', '_')
        filename = f"{safe_doi}.md"
    else:
        doc_id = doc_dict.get('id', 'unknown')
        filename = f"doc_{doc_id}.md"

    return output_dir / filename


def find_existing_fulltext(
    doc_dict: Dict[str, Any],
    base_dir: Optional[Path] = None,
) -> Optional[Path]:
    """
    Check if full-text markdown already exists locally for this document.

    Searches both the expected path and year-based subdirectories
    to find existing full-text that may have been stored previously.

    Args:
        doc_dict: Document dictionary with pmcid, pmid, doi, year, id, etc.
        base_dir: Base directory for full-text storage (default: from get_fulltext_base_dir())

    Returns:
        Path to existing full-text markdown if found, None otherwise

    Example:
        doc = {'pmcid': 'PMC12101959', 'year': 2024}
        existing = find_existing_fulltext(doc)
        if existing:
            print(f"Found full-text at: {existing}")
    """
    if base_dir is None:
        base_dir = get_fulltext_base_dir()

    # First check expected path
    expected_path = generate_fulltext_path(doc_dict, base_dir)
    if expected_path.exists():
        logger.info(f"Found existing full-text at: {expected_path}")
        return expected_path

    # Also check by PMC ID in all year directories
    pmcid = doc_dict.get('pmcid') or doc_dict.get('pmc_id')
    if pmcid:
        pmc_num = pmcid.replace("PMC", "")
        filename = f"PMC{pmc_num}.md"

        if base_dir.exists():
            for year_dir in base_dir.iterdir():
                if year_dir.is_dir():
                    fulltext_path = year_dir / filename
                    if fulltext_path.exists():
                        logger.info(f"Found existing full-text at: {fulltext_path}")
                        return fulltext_path

    # Also check by PMID
    pmid = doc_dict.get('pmid')
    if pmid:
        filename = f"pmid_{pmid}.md"
        if base_dir.exists():
            for year_dir in base_dir.iterdir():
                if year_dir.is_dir():
                    fulltext_path = year_dir / filename
                    if fulltext_path.exists():
                        logger.info(f"Found existing full-text at: {fulltext_path}")
                        return fulltext_path

    return None


#: How every cache stamp opens, whatever its version.
_CACHE_STAMP_PREFIX = "<!-- bmlibrarian-lite jats-markdown v"


def fulltext_cache_stamp(version: int = JATS_MARKDOWN_CONVERTER_VERSION) -> str:
    """The first line of a cached full-text markdown file.

    An HTML comment, so it renders as nothing wherever the file is opened as
    markdown. It names the converter that wrote the file: the cache is read
    before Europe PMC is asked, so without it a converter fix would never
    reach an article already cached (#420).

    Args:
        version: The converter version to stamp.

    Returns:
        The stamp line, without its newline.
    """
    return f"{_CACHE_STAMP_PREFIX}{version} -->"


def save_fulltext_markdown(
    doc_dict: Dict[str, Any],
    markdown_content: str,
    base_dir: Optional[Path] = None,
) -> Path:
    """
    Save full-text markdown to the cache directory.

    The file opens with :func:`fulltext_cache_stamp`, which
    :func:`read_cached_fulltext` checks and strips.

    Args:
        doc_dict: Document dictionary with pmcid, pmid, doi, year, etc.
        markdown_content: Markdown content to save
        base_dir: Base directory for full-text storage

    Returns:
        Path where the file was saved

    Example:
        path = save_fulltext_markdown(
            {'pmcid': 'PMC12101959', 'year': 2024},
            "# Article Title\n\nContent..."
        )
    """
    path = generate_fulltext_path(doc_dict, base_dir)
    path.parent.mkdir(parents=True, exist_ok=True)
    # Written aside and moved into place: a write cut short by a full disk
    # or a killed process left a stamped file holding half an article, read
    # as current for good -- and if the cut fell before the competing
    # interests statement, charged as an article that makes none.
    partial = path.with_name(f"{path.name}.partial")
    try:
        partial.write_text(f"{fulltext_cache_stamp()}\n{markdown_content}", encoding='utf-8')
        os.replace(partial, path)
    except OSError:
        partial.unlink(missing_ok=True)
        raise
    logger.info(f"Saved full-text markdown to: {path}")
    return path


def read_cached_fulltext(path: Path) -> str | None:
    """Read cached full-text markdown written by the current converter.

    Args:
        path: A file :func:`find_existing_fulltext` found.

    Returns:
        The markdown without its stamp; or ``None`` when the file carries no
        stamp or another converter's, so the caller converts the article
        again, or when nothing follows the stamp. A cached file is never
        written empty, so an empty one is damaged, and serving it as a hit
        would stop the article ever being fetched again.

    Raises:
        OSError: If the file cannot be read.
        UnicodeDecodeError: If it is not UTF-8.
    """
    stamp, markdown = split_cache_stamp(path.read_text(encoding='utf-8'))
    if stamp != fulltext_cache_stamp():
        logger.info(
            "Cached full text at %s was written by an earlier converter; "
            "converting it again.",
            path,
        )
        return None
    if not markdown.strip():
        logger.warning("Cached full text at %s is empty; fetching it again.", path)
        return None
    return markdown


def read_stale_cached_fulltext(path: Path) -> str | None:
    """Read cached full-text markdown, whichever converter wrote it.

    For a reader who would otherwise be shown only the abstract, when the
    article could not be fetched again. Never for the transparency analyser:
    an earlier converter dropped the statements it reads, and their silence
    would be charged to the study.

    Args:
        path: A file :func:`find_existing_fulltext` found.

    Returns:
        The markdown without any stamp, or ``None`` when nothing is left.

    Raises:
        OSError: If the file cannot be read.
        UnicodeDecodeError: If it is not UTF-8.
    """
    _, markdown = split_cache_stamp(path.read_text(encoding='utf-8'))
    return markdown if markdown.strip() else None


def split_cache_stamp(content: str) -> tuple[str | None, str]:
    """Split a cached file's stamp from its markdown.

    Args:
        content: The file's content.

    Returns:
        The stamp line, stripped, or ``None`` when the file opens with none
        (every file written before the stamp existed); and the markdown.
    """
    first_line, _, rest = content.partition("\n")
    if first_line.strip().startswith(_CACHE_STAMP_PREFIX):
        return first_line.strip(), rest
    return None, content


def format_abstract_as_document(
    title: Optional[str],
    authors: Optional[str],
    journal: Optional[str],
    year: Optional[int],
    doi: Optional[str],
    pmid: Optional[str],
    abstract: Optional[str],
    passage: Optional[str] = None,
    context: Optional[str] = None,
) -> str:
    """
    Format abstract and metadata as a readable markdown document.

    Creates a structured document from the abstract and metadata
    when full text is not available.

    Args:
        title: Document title
        authors: Formatted author string
        journal: Journal name
        year: Publication year
        doi: Digital Object Identifier
        pmid: PubMed ID
        abstract: Document abstract
        passage: Optional relevant passage from citation
        context: Optional additional context

    Returns:
        Formatted markdown document text

    Example:
        text = format_abstract_as_document(
            title="A Study on X",
            authors="Smith J, Johnson A",
            journal="Nature",
            year=2023,
            doi="10.1038/nature12373",
            pmid="12345678",
            abstract="This study investigates...",
            passage="The key finding was...",
        )
    """
    parts = []

    # Title
    parts.append(f"# {title or 'Untitled Document'}")
    parts.append("")

    # Authors and publication info
    if authors:
        parts.append(f"**Authors:** {authors}")
    if journal:
        parts.append(f"**Journal:** {journal}")
    if year:
        parts.append(f"**Year:** {year}")
    if doi:
        parts.append(f"**DOI:** {doi}")
    if pmid:
        parts.append(f"**PMID:** {pmid}")

    parts.append("")

    # Abstract
    parts.append("## Abstract")
    parts.append("")
    parts.append(abstract or "No abstract available.")
    parts.append("")

    # Relevant passage from citation
    if passage:
        parts.append("## Relevant Passage")
        parts.append("")
        parts.append(f"> {passage}")
        parts.append("")

    # Context if available
    if context:
        parts.append("## Context")
        parts.append("")
        parts.append(context)
        parts.append("")

    # Note about limited content
    parts.append("---")
    parts.append("")
    parts.append(
        "*Note: Full text was not available. This document contains only "
        "the abstract and citation information.*"
    )

    return "\n".join(parts)


def extract_pdf_text(pdf_path: Path) -> str:
    """
    Extract text from a PDF file.

    Uses PyMuPDF (fitz) to extract text from all pages.

    Args:
        pdf_path: Path to PDF file

    Returns:
        Extracted text from all pages, joined by double newlines

    Raises:
        FileNotFoundError: If PDF file doesn't exist
        Exception: If PDF cannot be opened or read

    Example:
        text = extract_pdf_text(Path("/path/to/paper.pdf"))
        print(f"Extracted {len(text)} characters")
    """
    import fitz

    if not pdf_path.exists():
        raise FileNotFoundError(f"PDF file not found: {pdf_path}")

    pdf_doc = fitz.open(str(pdf_path))
    text_parts = []

    try:
        for page in pdf_doc:
            text_parts.append(page.get_text())
    finally:
        pdf_doc.close()

    return "\n\n".join(text_parts)


def get_progress_stage_message(stage: str, status: str) -> str:
    """
    Get a user-friendly message for PDF progress stages.

    Maps internal stage/status codes to human-readable messages.

    Args:
        stage: Current stage (discovery, download, browser_download, verification)
        status: Current status (starting, found, success, failed, etc.)

    Returns:
        User-friendly message string

    Example:
        msg = get_progress_stage_message('discovery', 'starting')
        # Returns "Searching for PDF sources..."
    """
    stage_messages = {
        'discovery': {
            'starting': "Searching for PDF sources...",
            'resolving': "Checking PDF sources...",
            'found': "Found PDF source!",
            'found_oa': "Found open access PDF!",
            'not_found': "No PDF sources found",
            'error': "Error searching for PDF",
        },
        'download': {
            'starting': "Downloading PDF...",
            'success': "Download complete!",
            'failed': "Download failed",
        },
        'browser_download': {
            'starting': "Downloading PDF (browser mode)...",
            'success': "Download complete!",
            'failed': "Browser download failed",
        },
        'verification': {
            'starting': "Verifying PDF content...",
            'success': "Verification complete",
            'mismatch': "Content verification failed",
            'skipped': "Verification skipped",
            'error': "Verification error",
        },
    }

    return stage_messages.get(stage, {}).get(
        status, f"{stage.replace('_', ' ').title()}: {status}"
    )
