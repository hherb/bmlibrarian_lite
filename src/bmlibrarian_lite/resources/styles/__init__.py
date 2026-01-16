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
Qt UI styling system with DPI-aware font-relative dimensions.

This module provides centralized styling utilities that ensure consistent
appearance across different screen DPIs and user font preferences.

Usage:
    from bmlibrarian_lite.resources.styles import get_font_scale, StylesheetGenerator

    # Get scaling dictionary
    scale = get_font_scale()

    # Use in f-strings
    widget.setStyleSheet(f"font-size: {scale['font_medium']}pt;")

    # Or use StylesheetGenerator for common patterns
    gen = StylesheetGenerator()
    button.setStyleSheet(gen.button_stylesheet())
"""

from .dpi_scale import (
    FontScale,
    get_font_scale,
    get_scale_value,
    scale_px,
    scaled,
    get_system_font_family,
    get_monospace_font_family,
    FONT_FAMILY,
    FONT_FAMILY_MONOSPACE,
)

from .stylesheet_generator import (
    StylesheetGenerator,
    get_stylesheet_generator,
    apply_button_style,
    apply_input_style,
    apply_header_style,
)

from .theme_generator import (
    generate_default_theme,
    generate_dark_theme,
)

from .theme_colors import (
    ThemeColors,
    MaterialColors,
    COLOR_SUCCESS_BG,
    COLOR_SUCCESS_BORDER,
    COLOR_SUCCESS_TEXT,
    COLOR_TEXT_MUTED,
)

__all__ = [
    # DPI scaling
    'FontScale',
    'get_font_scale',
    'get_scale_value',
    'scale_px',
    'scaled',
    'get_system_font_family',
    'get_monospace_font_family',
    'FONT_FAMILY',
    'FONT_FAMILY_MONOSPACE',

    # Stylesheet generation
    'StylesheetGenerator',
    'get_stylesheet_generator',
    'apply_button_style',
    'apply_input_style',
    'apply_header_style',

    # Theme generation
    'generate_default_theme',
    'generate_dark_theme',

    # Theme colors
    'ThemeColors',
    'MaterialColors',
    'COLOR_SUCCESS_BG',
    'COLOR_SUCCESS_BORDER',
    'COLOR_SUCCESS_TEXT',
    'COLOR_TEXT_MUTED',
]
