#!/usr/bin/env python3
"""
Example Usage of Study Transparency Analyzer
=============================================

This script demonstrates various ways to use the analyzer.
Replace 'your@email.com' with your actual email address.
"""

import json
from study_transparency_analyzer import (
    StudyTransparencyAnalyzer,
    SponsorType,
    DataDisclosureLevel,
)


def example_single_study():
    """Example: Analyze a single study by PMID."""
    print("=" * 60)
    print("EXAMPLE 1: Single Study Analysis (by PMID)")
    print("=" * 60)

    # Initialize analyzer
    analyzer = StudyTransparencyAnalyzer(
        email="your@email.com",
        # pubmed_api_key="YOUR_KEY"  # Optional, for higher rate limits
    )

    # Analyze the BNT162b2 (Pfizer) COVID vaccine trial
    report = analyzer.analyze(pmid="33301246")

    # Access basic information
    print(f"\nTitle: {report.title}")
    print(f"Journal: {report.journal}")
    print(f"DOI: {report.doi}")

    # Check sponsorship
    print(f"\nSponsor Type: {report.sponsor_type.value}")
    print(f"Industry Funded: {report.industry_funding_detected}")
    if report.industry_funding_detected:
        print(f"Confidence: {report.industry_funding_confidence:.0%}")

    # List funders
    if report.funders:
        print("\nFunders:")
        for funder in report.funders:
            tag = " [INDUSTRY]" if funder.is_industry else ""
            print(f"  - {funder.name}{tag}")

    # Check trial registration
    if report.trial_registrations:
        print("\nTrial Registrations:")
        for trial in report.trial_registrations:
            print(f"  - {trial.registration_id}")
            print(f"    Sponsor Class: {trial.sponsor_class}")
            print(f"    Results Posted: {trial.results_posted}")

    # Data availability
    if report.data_availability:
        print(f"\nData Availability: {report.data_availability.disclosure_level.value}")

    # Overall scores
    print(f"\nTransparency Score: {report.transparency_score:.0f}/100")

    # Risk indicators
    if report.risk_of_bias_indicators:
        print("\nRisk Indicators:")
        for indicator in report.risk_of_bias_indicators:
            print(f"  ⚠️  {indicator}")

    return report


def example_doi_analysis():
    """Example: Analyze a study by DOI."""
    print("\n" + "=" * 60)
    print("EXAMPLE 2: Analysis by DOI")
    print("=" * 60)

    analyzer = StudyTransparencyAnalyzer(email="your@email.com")

    # Analyze by DOI
    report = analyzer.analyze(doi="10.1016/S0140-6736(20)32661-1")

    print(f"\nTitle: {report.title}")
    print(f"Sponsor Type: {report.sponsor_type.value}")
    print(f"Transparency Score: {report.transparency_score:.0f}/100")

    return report


def example_json_export():
    """Example: Export results to JSON."""
    print("\n" + "=" * 60)
    print("EXAMPLE 3: JSON Export")
    print("=" * 60)

    analyzer = StudyTransparencyAnalyzer(email="your@email.com")
    report = analyzer.analyze(pmid="33301246")

    # Convert to dictionary
    report_dict = report.to_dict()

    # Pretty print JSON
    print("\nJSON Output (truncated):")
    print(json.dumps(report_dict, indent=2)[:1000] + "...")

    # Save to file
    with open("example_report.json", "w") as f:
        json.dump(report_dict, f, indent=2)
    print("\nSaved full report to: example_report.json")


def example_batch_analysis():
    """Example: Analyze multiple studies."""
    print("\n" + "=" * 60)
    print("EXAMPLE 4: Batch Analysis")
    print("=" * 60)

    from batch_analyzer import BatchAnalyzer, generate_summary_report

    # List of studies to analyze
    studies = [
        {"pmid": "33301246"},  # Pfizer vaccine
        {"pmid": "33306989"},  # AstraZeneca vaccine
        {"doi": "10.1056/NEJMoa2035389"},  # Moderna vaccine
    ]

    # Initialize batch analyzer
    batch = BatchAnalyzer(
        email="your@email.com",
        max_workers=2  # Be gentle with APIs
    )

    # Run analysis (sequential, rate-limited)
    print("\nAnalyzing 3 studies...")
    result = batch.analyze_batch(studies, delay_between=1.5)

    # Print summary
    print(generate_summary_report(result))

    return result


def example_filtering_results():
    """Example: Filter and analyze results programmatically."""
    print("\n" + "=" * 60)
    print("EXAMPLE 5: Filtering Results")
    print("=" * 60)

    from batch_analyzer import BatchAnalyzer

    studies = [
        {"pmid": "33301246"},
        {"pmid": "33306989"},
        {"pmid": "33378609"},
    ]

    batch = BatchAnalyzer(email="your@email.com")
    result = batch.analyze_batch(studies, delay_between=1.0)

    # Filter: Industry-funded with restricted data
    high_risk = [
        r for r in result.reports
        if r.industry_funding_detected
        and r.data_availability
        and r.data_availability.disclosure_level in [
            DataDisclosureLevel.RESTRICTED,
            DataDisclosureLevel.NOT_AVAILABLE
        ]
    ]

    print(f"\nFound {len(high_risk)} industry-funded studies with restricted data:")
    for r in high_risk:
        print(f"  - {r.pmid}: {r.title[:50]}...")

    # Filter: Studies with missing trial results
    missing_results = [
        r for r in result.reports
        if any(
            not trial.results_posted
            for trial in r.trial_registrations
        )
    ]

    print(f"\nFound {len(missing_results)} studies with trial results not posted")


def example_custom_scoring():
    """Example: Custom transparency scoring."""
    print("\n" + "=" * 60)
    print("EXAMPLE 6: Custom Scoring")
    print("=" * 60)

    analyzer = StudyTransparencyAnalyzer(email="your@email.com")
    report = analyzer.analyze(pmid="33301246")

    # Custom scoring function
    def custom_score(report):
        """Custom scoring emphasizing data sharing."""
        score = 0

        # Heavy weight on data availability (50 points max)
        if report.data_availability:
            level = report.data_availability.disclosure_level
            if level == DataDisclosureLevel.FULL_OPEN:
                score += 50
            elif level == DataDisclosureLevel.AVAILABLE_ON_REQUEST:
                score += 25
            elif level == DataDisclosureLevel.RESTRICTED:
                score += 10

        # Trial registration (30 points max)
        if report.trial_registrations:
            score += 20
            if all(t.results_posted for t in report.trial_registrations):
                score += 10

        # COI disclosure (20 points max)
        if report.coi_info and report.coi_info.statement:
            score += 20

        return score

    custom = custom_score(report)
    print(f"\nDefault Transparency Score: {report.transparency_score:.0f}/100")
    print(f"Custom Score (data-weighted): {custom}/100")


def example_comparison():
    """Example: Compare industry vs. non-industry funded studies."""
    print("\n" + "=" * 60)
    print("EXAMPLE 7: Industry vs Non-Industry Comparison")
    print("=" * 60)

    # This would typically use a larger dataset
    # Here we use a small example

    from batch_analyzer import BatchAnalyzer

    # Mix of industry and government-funded studies
    studies = [
        {"pmid": "33301246"},  # Industry (Pfizer)
        {"pmid": "33306989"},  # Industry (AstraZeneca)
        # Add government-funded studies here
    ]

    batch = BatchAnalyzer(email="your@email.com")
    result = batch.analyze_batch(studies, delay_between=1.0)

    # Separate by funding source
    industry_reports = [r for r in result.reports if r.industry_funding_detected]
    other_reports = [r for r in result.reports if not r.industry_funding_detected]

    if industry_reports:
        avg_industry = sum(r.transparency_score for r in industry_reports) / len(industry_reports)
        print(f"\nIndustry-funded ({len(industry_reports)} studies):")
        print(f"  Average Transparency Score: {avg_industry:.1f}")

    if other_reports:
        avg_other = sum(r.transparency_score for r in other_reports) / len(other_reports)
        print(f"\nOther funding ({len(other_reports)} studies):")
        print(f"  Average Transparency Score: {avg_other:.1f}")


if __name__ == "__main__":
    print("""
╔════════════════════════════════════════════════════════════════╗
║         STUDY TRANSPARENCY ANALYZER - EXAMPLES                 ║
║                                                                ║
║  NOTE: Replace 'your@email.com' with your actual email        ║
║  These examples make real API calls and may take a moment     ║
╚════════════════════════════════════════════════════════════════╝
    """)

    # Uncomment the examples you want to run:

    example_single_study()
    example_doi_analysis()
    # example_json_export()
    # example_batch_analysis()
    # example_filtering_results()
    # example_custom_scoring()
    # example_comparison()

    print("\nUncomment the examples in the script to run them!")
    print("Start with: example_single_study()")
