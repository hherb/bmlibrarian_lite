"""Error text shown to the reader carries no credential (#330)."""

import pytest

from bmlibrarian_lite.analysis_failures import also_failed_text, redact_secrets


def test_a_url_query_string_is_redacted() -> None:
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
    out = redact_secrets(text)
    assert secret not in out
    assert "[redacted]" in out


def test_plain_error_text_is_unchanged() -> None:
    assert redact_secrets("Connection refused") == "Connection refused"


def test_also_failed_text_never_shows_the_key() -> None:
    assert "SECRET" not in also_failed_text("boom http://h/x?key=SECRET")
    assert also_failed_text("") == ""
