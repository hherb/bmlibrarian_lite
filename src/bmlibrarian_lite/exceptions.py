"""
Custom exceptions for BMLibrarian Lite.

Provides a hierarchy of specific exception types for different failure modes,
enabling precise error handling and meaningful error messages.

Exception Hierarchy:
    LiteError (base)
    ├── LiteStorageError
    │   └── SQLiteError
    ├── EmbeddingError
    ├── ConfigurationError
    ├── NetworkError
    └── LLMError

Usage:
    from bmlibrarian_lite.exceptions import SQLiteError

    try:
        storage.add_document(doc)
    except SQLiteError as e:
        logger.error(f"Storage operation failed: {e}")
"""


class LiteError(Exception):
    """
    Base exception for BMLibrarian Lite.

    All Lite-specific exceptions inherit from this class,
    allowing catch-all handling when needed.

    Example:
        try:
            do_something()
        except LiteError as e:
            logger.error(f"Lite operation failed: {e}")
    """

    pass


class LiteStorageError(LiteError):
    """
    Base exception for storage operations.

    Use more specific subclasses when the storage type is known.

    Example:
        try:
            storage.add_document(doc)
        except LiteStorageError as e:
            logger.error(f"Storage operation failed: {e}")
    """

    pass


class SQLiteError(LiteStorageError):
    """
    SQLite-specific storage error.

    Raised when SQLite operations fail, including:
    - Connection errors
    - Query execution failures
    - Schema issues

    Example:
        try:
            conn.execute("INSERT INTO ...", values)
        except sqlite3.Error as e:
            raise SQLiteError(f"Database insert failed: {e}") from e
    """

    pass


class EmbeddingError(LiteError):
    """
    Embedding generation error.

    Raised when FastEmbed operations fail, including:
    - Model loading failures
    - Embedding generation timeouts
    - Out-of-memory errors

    Example:
        try:
            embeddings = embedder.embed(texts)
        except Exception as e:
            raise EmbeddingError(f"Embedding generation failed: {e}") from e
    """

    pass


class ConfigurationError(LiteError):
    """
    Configuration validation or loading error.

    Raised when configuration is invalid or cannot be loaded:
    - Invalid parameter values
    - Missing required fields
    - File read/write errors

    Example:
        errors = config.validate()
        if errors:
            raise ConfigurationError(f"Invalid configuration: {', '.join(errors)}")
    """

    pass


class NetworkError(LiteError):
    """
    Network operation error.

    Raised when network requests fail, including:
    - PubMed API errors
    - Connection timeouts
    - HTTP errors

    Example:
        try:
            response = client.search(query)
        except (ConnectionError, TimeoutError) as e:
            raise NetworkError(f"PubMed search failed: {e}") from e
    """

    pass


class LLMError(LiteError):
    """
    LLM API error.

    Raised when LLM operations fail, including:
    - API authentication errors
    - Rate limiting
    - Model errors
    - Response parsing failures

    Example:
        try:
            response = llm_client.chat(messages)
        except Exception as e:
            raise LLMError(f"LLM request failed: {e}") from e
    """

    pass


class RetryExhaustedError(NetworkError):
    """
    All retry attempts exhausted.

    Raised when an operation fails after all retry attempts.
    Contains information about the number of attempts and last error.

    Example:
        raise RetryExhaustedError(
            f"Operation failed after {max_retries} attempts",
            attempts=max_retries,
            last_error=last_exception
        )
    """

    def __init__(
        self,
        message: str,
        attempts: int = 0,
        last_error: Exception | None = None,
    ) -> None:
        """
        Initialize retry exhausted error.

        Args:
            message: Error message
            attempts: Number of retry attempts made
            last_error: The last exception that occurred
        """
        super().__init__(message)
        self.attempts = attempts
        self.last_error = last_error


class JSONParseError(LLMError):
    """
    JSON parsing failed for LLM response.

    Raised when the LLM returns a response that cannot be parsed as JSON,
    including malformed JSON or unexpected response format.

    Example:
        raise JSONParseError(
            "Failed to parse scoring response",
            raw_response=llm_response,
        )
    """

    def __init__(
        self,
        message: str,
        raw_response: str | None = None,
    ) -> None:
        """
        Initialize JSON parse error.

        Args:
            message: Error message
            raw_response: The raw LLM response that failed to parse
        """
        super().__init__(message)
        self.raw_response = raw_response


class APIError(LLMError):
    """
    LLM API call failed.

    Raised when an LLM API call fails due to network issues, rate limiting,
    authentication errors, or other API-level failures.

    Example:
        raise APIError(
            "Anthropic API request failed",
            status_code=429,
            is_retryable=True,
        )
    """

    def __init__(
        self,
        message: str,
        status_code: int | None = None,
        is_retryable: bool = True,
    ) -> None:
        """
        Initialize API error.

        Args:
            message: Error message
            status_code: HTTP status code if available
            is_retryable: Whether this error can be retried
        """
        super().__init__(message)
        self.status_code = status_code
        self.is_retryable = is_retryable
