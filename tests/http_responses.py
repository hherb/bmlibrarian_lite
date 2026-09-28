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

"""Real ``requests`` responses and sessions for unit tests.

A real :class:`requests.Response` rather than a mock, so that
``raise_for_status`` and ``.text`` behave as they do live.
"""

from unittest.mock import MagicMock

import requests

from bmlibrarian_lite.constants import EUROPEPMC_REST_BASE_URL


def http_response(
    status: int,
    text: str = "",
    url: str = f"{EUROPEPMC_REST_BASE_URL}/PMC1/fullTextXML",
) -> requests.Response:
    """A real response with ``status`` and ``text``.

    Args:
        status: The HTTP status.
        text: The body.
        url: Where it claims to come from, named by ``raise_for_status``.

    Returns:
        The response.
    """
    response = requests.Response()
    response.status_code = status
    response._content = text.encode("utf-8")
    response.encoding = "utf-8"
    response.url = url
    return response


def session_answering(answer: object) -> MagicMock:
    """A session whose ``get`` returns, or raises, ``answer``.

    Args:
        answer: A response to return, or an exception to raise.

    Returns:
        The mocked session.
    """
    session = MagicMock()
    if isinstance(answer, BaseException):
        session.get.side_effect = answer
    else:
        session.get.return_value = answer
    return session
