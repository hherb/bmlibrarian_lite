"""A caller's PMID, read once: canonical ASCII digits, or not sent at all.

A PMID reaches Europe PMC's ``ext_id:`` query, NCBI's ID Converter and
efetch. Until it was checked it reached all three as given, and two things
went wrong (bmlib#470, bmlib#472, bmlib#478): Europe PMC finds nothing for a padded
``0033301246`` where ``33301246`` finds the paper, so a padded PMID read as
"Europe PMC holds no record"; and nothing required digits, so ``"1 OR 2"``
widened the query past its ``src:med`` guard.

The rules are shared with the Swift and Kotlin ports through
``doc/cross_platform/fulltext_parity/pmid_canonical.json``.
"""

from __future__ import annotations

import logging
import re
from dataclasses import dataclass

logger = logging.getLogger(__name__)

# ASCII only: ``\d`` alone also matches Arabic-Indic and other digits, which
# are not a PMID and which a URL would carry as they came.
_PMID_RE = re.compile(r"0*[1-9][0-9]*", re.ASCII)
_PMC_ID_RE = re.compile(r"PMC[0-9]+", re.ASCII)


@dataclass(frozen=True)
class PmidReading:
    """What a caller's PMID value turned out to be.

    Attributes:
        pmid: The canonical PMID (ASCII digits, no leading zeros), or
            ``None`` for none given or none usable.
        pmc_id: A PMC ID the caller passed as the PMID, or ``None``.
        refused: Whether the value was given and is neither a PMID nor a
            PMC ID. A blank is no PMID, and is not refused.
    """

    pmid: str | None = None
    pmc_id: str | None = None
    refused: bool = False


def canonical_pmid(value: object) -> PmidReading:
    """Read a caller's PMID.

    Surrounding whitespace (what ``str.strip()`` removes) is stripped and a
    blank is no PMID. An ``int`` is its decimal digits, and ``0`` is no PMID;
    a ``bool`` is refused although it is an ``int``, and so is an ``int``
    too long to convert to text. Text must be ASCII digits, not all zeros, and is
    returned without its leading zeros. ``PMC`` then ASCII digits is a PMC ID
    given as a PMID: no PMID carries that prefix, so it names the article's
    PMC record. Anything else is refused.

    Args:
        value: What the caller passed as the PMID.

    Returns:
        The reading; it never raises.
    """
    if value is None:
        return PmidReading()
    if isinstance(value, bool):
        return PmidReading(refused=True)
    if isinstance(value, int):
        if value == 0:
            return PmidReading()
        if value < 0:
            return PmidReading(refused=True)
        try:
            text = str(value)
        except ValueError:
            # Past the int-to-str digit limit (sys.get_int_max_str_digits()):
            # no PMID is that long, and the promise is never to raise.
            return PmidReading(refused=True)
    elif isinstance(value, str):
        text = str.strip(value)
    else:
        return PmidReading(refused=True)
    if not text:
        return PmidReading()
    if _PMID_RE.fullmatch(text):
        return PmidReading(pmid=text.lstrip("0"))
    if _PMC_ID_RE.fullmatch(text):
        return PmidReading(pmc_id=text)
    return PmidReading(refused=True)


def is_canonical_pmid(value: object) -> bool:
    """Whether *value* is text that is already a canonical PMID."""
    reading = canonical_pmid(value)
    return isinstance(value, str) and reading.pmid is not None and reading.pmid == value


def read_caller_ids(
    pmid: object, pmcid: str | None = None
) -> tuple[str | None, str | None]:
    """Read a caller's PMID beside its PMC ID, logging what is refused.

    A refused PMID is the caller's, so it is logged naming the value and the
    call goes on as though no PMID had been given, as it does for a malformed
    PMC ID. A PMC ID passed as the PMID fills *pmcid* only when the caller
    gave none.

    Args:
        pmid: What the caller passed as the PMID.
        pmcid: The PMC ID the caller passed, if any.

    Returns:
        ``(pmid, pmcid)``: the canonical PMID or ``None``, and the PMC ID.
    """
    reading = canonical_pmid(pmid)
    if reading.refused:
        logger.warning(
            "Not a usable PMID, so it was not sent: %r; continuing without it",
            pmid,
        )
    if reading.pmc_id is not None:
        if pmcid:
            logger.warning(
                "The PMID %r is a PMC ID, and a PMC ID was also given, so "
                "the PMID was not used",
                pmid,
            )
        else:
            logger.warning("The PMID %r is a PMC ID, so it is read as one", pmid)
            pmcid = reading.pmc_id
    return reading.pmid, pmcid
