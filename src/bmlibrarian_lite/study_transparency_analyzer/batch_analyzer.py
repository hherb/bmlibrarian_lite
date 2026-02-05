#!/usr/bin/env python3
"""
Batch Analyzer for Study Transparency
======================================

Process multiple studies from a CSV/file and generate aggregate reports.
"""

import csv
import json
import time
import logging
from pathlib import Path
from typing import List, Dict, Optional
from dataclasses import dataclass
from concurrent.futures import ThreadPoolExecutor, as_completed
import argparse

from .study_transparency_analyzer import (
    StudyTransparencyAnalyzer,
    TransparencyReport,
    SponsorType,
    DataDisclosureLevel,
    ResultsComplianceStatus
)

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


@dataclass
class BatchResult:
    """Results from batch processing."""
    total_studies: int
    successful: int
    failed: int
    reports: List[TransparencyReport]
    errors: Dict[str, str]  # ID -> error message

    # Aggregate statistics
    industry_funded_count: int = 0
    full_open_data_count: int = 0
    restricted_data_count: int = 0
    no_data_statement_count: int = 0
    missing_results_count: int = 0

    def calculate_statistics(self):
        """Calculate aggregate statistics from reports."""
        for report in self.reports:
            if report.industry_funding_detected:
                self.industry_funded_count += 1

            if report.data_availability:
                level = report.data_availability.disclosure_level
                if level == DataDisclosureLevel.FULL_OPEN:
                    self.full_open_data_count += 1
                elif level in [DataDisclosureLevel.RESTRICTED, DataDisclosureLevel.NOT_AVAILABLE]:
                    self.restricted_data_count += 1
                elif level == DataDisclosureLevel.NOT_STATED:
                    self.no_data_statement_count += 1

            if report.results_compliance == ResultsComplianceStatus.MISSING:
                self.missing_results_count += 1

    def to_summary_dict(self) -> Dict:
        """Convert to summary dictionary."""
        return {
            'total_studies': self.total_studies,
            'successful_analyses': self.successful,
            'failed_analyses': self.failed,
            'statistics': {
                'industry_funded': self.industry_funded_count,
                'industry_funded_percent': (self.industry_funded_count / self.successful * 100) if self.successful else 0,
                'full_open_data': self.full_open_data_count,
                'restricted_data': self.restricted_data_count,
                'no_data_statement': self.no_data_statement_count,
                'missing_trial_results': self.missing_results_count,
            },
            'average_transparency_score': (
                sum(r.transparency_score for r in self.reports) / len(self.reports)
                if self.reports else 0
            ),
        }


def read_ids_from_csv(filepath: str, doi_column: str = 'doi', pmid_column: str = 'pmid') -> List[Dict]:
    """Read study IDs from CSV file."""
    studies = []
    with open(filepath, 'r', encoding='utf-8') as f:
        reader = csv.DictReader(f)
        for row in reader:
            study = {}
            if doi_column in row and row[doi_column].strip():
                study['doi'] = row[doi_column].strip()
            if pmid_column in row and row[pmid_column].strip():
                study['pmid'] = row[pmid_column].strip()
            if study:
                studies.append(study)
    return studies


def read_ids_from_text(filepath: str) -> List[Dict]:
    """
    Read study IDs from text file (one per line).
    Automatically detects DOI vs PMID format.
    """
    studies = []
    with open(filepath, 'r', encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue

            study = {}
            if '10.' in line:  # Looks like a DOI
                study['doi'] = line
            elif line.isdigit():  # Looks like a PMID
                study['pmid'] = line
            else:
                logger.warning(f"Could not identify ID type for: {line}")
                continue
            studies.append(study)
    return studies


class BatchAnalyzer:
    """Batch processor for study transparency analysis."""

    def __init__(self, email: str, api_key: Optional[str] = None, max_workers: int = 3):
        """
        Initialize batch analyzer.

        Args:
            email: Contact email for APIs
            api_key: NCBI API key
            max_workers: Max parallel workers (be gentle with APIs)
        """
        self.email = email
        self.api_key = api_key
        self.max_workers = max_workers

    def analyze_batch(
        self,
        studies: List[Dict],
        delay_between: float = 1.0,
        progress_callback=None
    ) -> BatchResult:
        """
        Analyze a batch of studies.

        Args:
            studies: List of dicts with 'doi' and/or 'pmid' keys
            delay_between: Seconds to wait between analyses
            progress_callback: Optional callback(current, total, study_id)

        Returns:
            BatchResult with all reports and statistics
        """
        result = BatchResult(
            total_studies=len(studies),
            successful=0,
            failed=0,
            reports=[],
            errors={}
        )

        # Create analyzer (use single instance for connection pooling)
        analyzer = StudyTransparencyAnalyzer(self.email, self.api_key)

        for i, study in enumerate(studies):
            study_id = study.get('doi') or study.get('pmid') or f"study_{i}"

            if progress_callback:
                progress_callback(i + 1, len(studies), study_id)
            else:
                logger.info(f"Processing {i+1}/{len(studies)}: {study_id}")

            try:
                report = analyzer.analyze(
                    doi=study.get('doi'),
                    pmid=study.get('pmid')
                )

                if report.errors:
                    result.failed += 1
                    result.errors[study_id] = "; ".join(report.errors)
                else:
                    result.successful += 1
                    result.reports.append(report)

            except Exception as e:
                logger.error(f"Error analyzing {study_id}: {e}")
                result.failed += 1
                result.errors[study_id] = str(e)

            # Rate limiting
            if i < len(studies) - 1:
                time.sleep(delay_between)

        # Calculate aggregate statistics
        result.calculate_statistics()

        return result

    def analyze_batch_parallel(
        self,
        studies: List[Dict],
        progress_callback=None
    ) -> BatchResult:
        """
        Analyze studies in parallel (use with caution - may hit rate limits).

        Args:
            studies: List of dicts with 'doi' and/or 'pmid' keys
            progress_callback: Optional callback(current, total, study_id)

        Returns:
            BatchResult with all reports and statistics
        """
        result = BatchResult(
            total_studies=len(studies),
            successful=0,
            failed=0,
            reports=[],
            errors={}
        )

        completed = 0

        def analyze_single(study: Dict, index: int):
            nonlocal completed
            analyzer = StudyTransparencyAnalyzer(self.email, self.api_key)
            study_id = study.get('doi') or study.get('pmid') or f"study_{index}"

            try:
                report = analyzer.analyze(
                    doi=study.get('doi'),
                    pmid=study.get('pmid')
                )
                return study_id, report, None
            except Exception as e:
                return study_id, None, str(e)

        with ThreadPoolExecutor(max_workers=self.max_workers) as executor:
            futures = {
                executor.submit(analyze_single, study, i): i
                for i, study in enumerate(studies)
            }

            for future in as_completed(futures):
                completed += 1
                study_id, report, error = future.result()

                if progress_callback:
                    progress_callback(completed, len(studies), study_id)

                if error:
                    result.failed += 1
                    result.errors[study_id] = error
                elif report and report.errors:
                    result.failed += 1
                    result.errors[study_id] = "; ".join(report.errors)
                else:
                    result.successful += 1
                    result.reports.append(report)

        result.calculate_statistics()
        return result


def export_to_csv(result: BatchResult, filepath: str):
    """Export batch results to CSV."""
    if not result.reports:
        logger.warning("No reports to export")
        return

    fieldnames = [
        'doi', 'pmid', 'title', 'journal',
        'sponsor_type', 'industry_funding', 'industry_funding_confidence',
        'data_disclosure_level', 'trial_registration_count', 'results_compliance',
        'coi_has_industry_ties', 'transparency_score', 'risk_indicators_count',
        'warnings'
    ]

    with open(filepath, 'w', newline='', encoding='utf-8') as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()

        for report in result.reports:
            row = {
                'doi': report.doi or '',
                'pmid': report.pmid or '',
                'title': (report.title or '')[:100],  # Truncate long titles
                'journal': report.journal or '',
                'sponsor_type': report.sponsor_type.value,
                'industry_funding': report.industry_funding_detected,
                'industry_funding_confidence': f"{report.industry_funding_confidence:.2f}",
                'data_disclosure_level': (
                    report.data_availability.disclosure_level.value
                    if report.data_availability else 'unknown'
                ),
                'trial_registration_count': len(report.trial_registrations),
                'results_compliance': report.results_compliance.value,
                'coi_has_industry_ties': (
                    report.coi_info.has_industry_ties if report.coi_info else ''
                ),
                'transparency_score': f"{report.transparency_score:.1f}",
                'risk_indicators_count': len(report.risk_of_bias_indicators),
                'warnings': '; '.join(report.warnings),
            }
            writer.writerow(row)

    logger.info(f"Exported {len(result.reports)} reports to {filepath}")


def export_to_json(result: BatchResult, filepath: str):
    """Export batch results to JSON."""
    output = {
        'summary': result.to_summary_dict(),
        'reports': [r.to_dict() for r in result.reports],
        'errors': result.errors,
    }

    with open(filepath, 'w', encoding='utf-8') as f:
        json.dump(output, f, indent=2, default=str)

    logger.info(f"Exported results to {filepath}")


def generate_summary_report(result: BatchResult) -> str:
    """Generate text summary of batch results."""
    lines = [
        "=" * 70,
        "BATCH ANALYSIS SUMMARY",
        "=" * 70,
        "",
        f"Total studies analyzed: {result.total_studies}",
        f"Successful: {result.successful}",
        f"Failed: {result.failed}",
        "",
        "AGGREGATE FINDINGS:",
        "-" * 40,
    ]

    if result.successful > 0:
        pct_industry = (result.industry_funded_count / result.successful) * 100
        pct_open = (result.full_open_data_count / result.successful) * 100
        pct_restricted = (result.restricted_data_count / result.successful) * 100
        pct_no_statement = (result.no_data_statement_count / result.successful) * 100
        avg_score = sum(r.transparency_score for r in result.reports) / result.successful

        lines.extend([
            f"Industry-funded studies: {result.industry_funded_count} ({pct_industry:.1f}%)",
            "",
            "Data Availability Breakdown:",
            f"  • Full open access: {result.full_open_data_count} ({pct_open:.1f}%)",
            f"  • Restricted/Not available: {result.restricted_data_count} ({pct_restricted:.1f}%)",
            f"  • No statement: {result.no_data_statement_count} ({pct_no_statement:.1f}%)",
            "",
            f"Missing trial results (ClinicalTrials.gov): {result.missing_results_count}",
            "",
            f"Average Transparency Score: {avg_score:.1f}/100",
        ])

        # Score distribution
        score_ranges = {'0-25': 0, '26-50': 0, '51-75': 0, '76-100': 0}
        for report in result.reports:
            score = report.transparency_score
            if score <= 25:
                score_ranges['0-25'] += 1
            elif score <= 50:
                score_ranges['26-50'] += 1
            elif score <= 75:
                score_ranges['51-75'] += 1
            else:
                score_ranges['76-100'] += 1

        lines.extend([
            "",
            "Transparency Score Distribution:",
            f"  • 0-25 (Poor): {score_ranges['0-25']}",
            f"  • 26-50 (Below Average): {score_ranges['26-50']}",
            f"  • 51-75 (Average): {score_ranges['51-75']}",
            f"  • 76-100 (Good): {score_ranges['76-100']}",
        ])

        # Most common risk indicators
        all_indicators = []
        for report in result.reports:
            all_indicators.extend(report.risk_of_bias_indicators)

        if all_indicators:
            from collections import Counter
            indicator_counts = Counter(all_indicators).most_common(5)

            lines.extend([
                "",
                "Most Common Risk Indicators:",
            ])
            for indicator, count in indicator_counts:
                lines.append(f"  • {indicator}: {count}")

    if result.errors:
        lines.extend([
            "",
            f"ERRORS ({len(result.errors)}):",
            "-" * 40,
        ])
        for study_id, error in list(result.errors.items())[:10]:
            lines.append(f"  {study_id}: {error[:60]}...")

    lines.append("=" * 70)
    return "\n".join(lines)


def main():
    """Command-line interface for batch analysis."""
    parser = argparse.ArgumentParser(
        description='Batch analyze medical studies for transparency'
    )
    parser.add_argument(
        'input_file',
        help='Input file (CSV or text with one ID per line)'
    )
    parser.add_argument(
        '--email',
        required=True,
        help='Your email address (required by APIs)'
    )
    parser.add_argument(
        '--api-key',
        help='NCBI API key for higher rate limits'
    )
    parser.add_argument(
        '--output-csv',
        help='Output CSV file path'
    )
    parser.add_argument(
        '--output-json',
        help='Output JSON file path'
    )
    parser.add_argument(
        '--doi-column',
        default='doi',
        help='Column name for DOI in CSV (default: doi)'
    )
    parser.add_argument(
        '--pmid-column',
        default='pmid',
        help='Column name for PMID in CSV (default: pmid)'
    )
    parser.add_argument(
        '--delay',
        type=float,
        default=1.0,
        help='Delay between API calls in seconds (default: 1.0)'
    )
    parser.add_argument(
        '--parallel',
        action='store_true',
        help='Use parallel processing (may hit rate limits)'
    )
    parser.add_argument(
        '--max-workers',
        type=int,
        default=3,
        help='Max parallel workers if --parallel (default: 3)'
    )

    args = parser.parse_args()

    # Load studies
    input_path = Path(args.input_file)
    if input_path.suffix.lower() == '.csv':
        studies = read_ids_from_csv(
            args.input_file,
            args.doi_column,
            args.pmid_column
        )
    else:
        studies = read_ids_from_text(args.input_file)

    if not studies:
        print("No studies found in input file")
        return

    print(f"Loaded {len(studies)} studies from {args.input_file}")

    # Run analysis
    batch_analyzer = BatchAnalyzer(
        args.email,
        args.api_key,
        max_workers=args.max_workers
    )

    if args.parallel:
        result = batch_analyzer.analyze_batch_parallel(studies)
    else:
        result = batch_analyzer.analyze_batch(studies, delay_between=args.delay)

    # Print summary
    print("\n" + generate_summary_report(result))

    # Export results
    if args.output_csv:
        export_to_csv(result, args.output_csv)

    if args.output_json:
        export_to_json(result, args.output_json)


if __name__ == '__main__':
    main()
