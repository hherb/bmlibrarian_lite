"""Allow running as python -m bmlibrarian_lite."""

import sys

from .cli import main

if __name__ == "__main__":
    sys.exit(main())
