"""Read a JSON value as the type a field is annotated with, or not at all.

Ported from bmlib's ``bmlib.quality._json_fields`` (bmlib#295, bmlib#320),
with the same semantics.  Every reader of a model's JSON reply in the quality
package -- the Tier 2 classifier and the Tier 3 assessor -- goes through
these, so the rule is stated once.

The rule: **absent, ``null`` and wrong-typed are the same answer -- unstated.**
``data.get(k, default)`` returns its default only for an *absent* key, so a
key present with ``null`` handed the reader ``None``; the Tier 3 prompt tells
the model to answer ``null`` for what the text does not report.  A wrong type
is the same case one step further: ``int(True)`` is 1, so a boolean became a
measured sample size, and ``float(True)`` is 1.0, the most confident answer
there is.  ``bool`` is excluded from every numeric reader for that reason, and
a non-finite float is refused because it is no measurement: ``json.loads``
accepts the bare tokens ``NaN``, ``Infinity`` and ``-Infinity``, and
``max(0, min(1, nan))`` is 1.0.

A refused value that was *present* is logged at DEBUG, naming the field; a
``null`` is what the prompt asks for and is not logged.

This module imports nothing from the package, so any module in it can use it
without a cycle.
"""

from __future__ import annotations

import logging
import math
from typing import Any

logger = logging.getLogger(__name__)


def _refused(field: str | None, value: object) -> None:
    """Log a present value that is not the type its field holds.

    Args:
        field: Name of the field, or None to stay silent.
        value: The refused value; ``None`` (a ``null``) is never logged.
    """
    if field is not None and value is not None:
        logger.debug(
            "Reading %s as unstated: the answer was a %s", field, type(value).__name__
        )


def as_dict(value: object, field: str | None = None) -> dict[str, Any]:
    """Return *value* when it is a JSON object, an empty dict otherwise.

    Args:
        value: The decoded JSON value.
        field: Field name for the DEBUG line, if any.

    Returns:
        The object itself, or ``{}``.
    """
    if isinstance(value, dict):
        return value
    _refused(field, value)
    return {}


def as_text(value: object, field: str | None = None) -> str | None:
    """Return *value* when it is a string, verbatim; ``None`` otherwise.

    A number is not stringified: ``5`` in an ``evidence_level`` is a level
    nobody named.

    Args:
        value: The decoded JSON value.
        field: Field name for the DEBUG line, if any.

    Returns:
        The string, or None.
    """
    if isinstance(value, str):
        return value
    _refused(field, value)
    return None


def text_or(value: object, default: str, field: str | None = None) -> str:
    """Return *value* when it is a string, *default* otherwise.

    An empty string is kept, as ``data.get(k, default)`` kept it.

    Args:
        value: The decoded JSON value.
        default: What an unstated value reads as.
        field: Field name for the DEBUG line, if any.

    Returns:
        The string or the default.
    """
    text = as_text(value, field)
    return default if text is None else text


def as_int(value: object, field: str | None = None) -> int | None:
    """Return *value* as an ``int``, or ``None``.

    A float is truncated and a string parsed with ``int()``.  A ``bool`` is
    refused, although Python counts it an ``int``; so is a non-finite float,
    since ``int(inf)`` raises ``OverflowError``.

    Args:
        value: The decoded JSON value.
        field: Field name for the DEBUG line, if any.

    Returns:
        The integer, or None.
    """
    result: int | None = None
    if isinstance(value, bool):
        result = None
    elif isinstance(value, int):
        result = value
    elif isinstance(value, float):
        result = int(value) if math.isfinite(value) else None
    elif isinstance(value, str):
        try:
            result = int(value)
        except ValueError:
            result = None
    if result is None:
        _refused(field, value)
    return result


def as_float(value: object, field: str | None = None) -> float | None:
    """Return *value* as a finite ``float``, or ``None``.

    A numeric string is parsed; a ``bool`` and anything non-finite are
    refused.

    Args:
        value: The decoded JSON value.
        field: Field name for the DEBUG line, if any.

    Returns:
        The finite float, or None.
    """
    result: float | None = None
    if isinstance(value, bool):
        result = None
    elif isinstance(value, (int, float)):
        result = float(value)
    elif isinstance(value, str):
        try:
            result = float(value)
        except ValueError:
            result = None
    if result is not None and not math.isfinite(result):
        result = None
    if result is None:
        _refused(field, value)
    return result


def as_bool(value: object, field: str | None = None) -> bool | None:
    """Return *value* when it is a JSON boolean, ``None`` otherwise.

    ``"true"`` and ``1`` are refused: ``bool("no")`` is ``True``, so coercing
    a string inverts the answer rather than losing it.

    Args:
        value: The decoded JSON value.
        field: Field name for the DEBUG line, if any.

    Returns:
        The boolean, or None.
    """
    if isinstance(value, bool):
        return value
    _refused(field, value)
    return None


def as_str_list(value: object, field: str | None = None) -> list[str] | None:
    """Return the string members of a JSON array, or ``None`` for a non-array.

    A non-string member is dropped rather than stringified.

    Args:
        value: The decoded JSON value.
        field: Field name for the DEBUG line, if any.

    Returns:
        The string members, or None when *value* is not an array.
    """
    if not isinstance(value, list):
        _refused(field, value)
        return None
    kept = [item for item in value if isinstance(item, str)]
    if len(kept) != len(value) and field is not None:
        logger.debug(
            "Dropped %d non-string member(s) of %s", len(value) - len(kept), field
        )
    return kept
