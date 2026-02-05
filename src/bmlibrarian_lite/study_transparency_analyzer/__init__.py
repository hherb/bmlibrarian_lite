"""
Study Transparency Analyzer
===========================

A tool for detecting industry sponsorship and data disclosure practices
in medical research publications.

Usage:
    from study_transparency_analyzer import StudyTransparencyAnalyzer

    analyzer = StudyTransparencyAnalyzer(email="your@email.com")
    report = analyzer.analyze(pmid="33301246")
    print(report.sponsor_type)
    print(report.transparency_score)
"""

from .study_transparency_analyzer import (
    StudyTransparencyAnalyzer,
    TransparencyReport,
    SponsorType,
    DataDisclosureLevel,
    ResultsComplianceStatus,
    FunderInfo,
    TrialRegistration,
    ConflictOfInterest,
    DataAvailabilityInfo,
)

from .batch_analyzer import (
    BatchAnalyzer,
    BatchResult,
    read_ids_from_csv,
    read_ids_from_text,
    export_to_csv,
    export_to_json,
    generate_summary_report,
)

__version__ = "1.0.0"
__author__ = "Medical Research Transparency Tools"

__all__ = [
    # Main analyzer
    "StudyTransparencyAnalyzer",

    # Report types
    "TransparencyReport",
    "FunderInfo",
    "TrialRegistration",
    "ConflictOfInterest",
    "DataAvailabilityInfo",

    # Enums
    "SponsorType",
    "DataDisclosureLevel",
    "ResultsComplianceStatus",

    # Batch processing
    "BatchAnalyzer",
    "BatchResult",
    "read_ids_from_csv",
    "read_ids_from_text",
    "export_to_csv",
    "export_to_json",
    "generate_summary_report",
]
