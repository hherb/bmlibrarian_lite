"""Error text shown to the reader carries no credential (#330)."""

import pytest

from bmlibrarian_lite.analysis_failures import also_failed_text, redact_secrets


def test_a_url_query_string_is_redacted() -> None:
    """A URL's query string is replaced, the rest of the URL kept."""
    assert (
        redact_secrets("Connection refused: http://localhost:11434/api/chat?key=SECRET")
        == "Connection refused: http://localhost:11434/api/chat?[redacted]"
    )


@pytest.mark.parametrize(
    ("text", "secret"),
    [
        ("Authorization: Bearer abc.def", "abc.def"),
        ("x-api-key: sk-ant-api03-XYZ", "sk-ant-api03-XYZ"),
        ("api_key=XYZ", "XYZ"),
    ],
)
def test_bearer_and_api_key_tokens_are_redacted(text: str, secret: str) -> None:
    """Bearer tokens and api-key values are replaced."""
    out = redact_secrets(text)
    assert secret not in out
    assert "[redacted]" in out


def test_plain_error_text_is_unchanged() -> None:
    """Text with no secret comes back as it was."""
    assert redact_secrets("Connection refused") == "Connection refused"


def test_also_failed_text_never_shows_the_key() -> None:
    """The cancelled run's added sentence carries no key."""
    assert "SECRET" not in also_failed_text("boom http://h/x?key=SECRET")
    assert also_failed_text("") == ""


def test_words_containing_sk_dash_are_unchanged() -> None:
    """A word that merely ends in "sk" is not mistaken for a key."""
    text = "risk-adjusted outcomes for a task-specific-thing"
    assert redact_secrets(text) == text
