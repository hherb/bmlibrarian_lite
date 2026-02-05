# Step 11: Testing Strategy

## Goal

Define the comprehensive testing strategy for the transparency analyzer.

## Test Organization

```
Tests/BioMedLitTests/Transparency/
├── Models/
│   ├── TransparencyModelsTests.swift
│   └── TransparencyConstantsTests.swift
├── Analysis/
│   ├── FundingAnalyzerTests.swift
│   ├── COIAnalyzerTests.swift
│   ├── DataAvailabilityAnalyzerTests.swift
│   ├── TrialComplianceAnalyzerTests.swift
│   └── TransparencyScorerTests.swift
├── Services/
│   ├── CrossRefServiceTests.swift
│   ├── ClinicalTrialsServiceTests.swift
│   └── TransparencyAnalysisServiceTests.swift
└── Integration/
    └── TransparencyIntegrationTests.swift
```

## Test Categories

### 1. Unit Tests (Pure Functions)

These tests run without network access and verify core logic.

```swift
// Example: FundingAnalyzerTests.swift
final class FundingAnalyzerTests: XCTestCase {

    // Test known industry funder DOI detection
    func testClassifyKnownIndustryFunderByDOI() {
        let (isIndustry, confidence) = FundingAnalyzer.classifyFunder(
            name: "Pfizer",
            doi: "10.13039/100004319"
        )
        XCTAssertTrue(isIndustry)
        XCTAssertEqual(confidence, 1.0)
    }

    // Test edge cases
    func testClassifyEmptyName() {
        let (isIndustry, confidence) = FundingAnalyzer.classifyFunder(name: "")
        XCTAssertFalse(isIndustry)
        XCTAssertLessThan(confidence, 0.5)
    }

    // Test all known funders are recognized
    func testAllKnownFunderDOIsRecognized() {
        for (doi, _) in KnownIndustryFunders.funderDOIs {
            XCTAssertTrue(
                KnownIndustryFunders.isIndustryFunder(doi),
                "Funder DOI \(doi) should be recognized"
            )
        }
    }
}
```

### 2. Service Tests (with Mocking)

Test service behavior with mocked network responses.

```swift
// Example: CrossRefServiceTests.swift with mock session
final class CrossRefServiceTests: XCTestCase {

    var mockSession: MockURLSession!
    var service: CrossRefService!

    override func setUp() {
        mockSession = MockURLSession()
        service = CrossRefService(email: "test@example.com", session: mockSession)
    }

    func testGetWorkSuccess() async throws {
        let mockResponse = """
        {
            "message": {
                "title": ["Test Article"],
                "funder": [{"name": "NIH"}]
            }
        }
        """
        mockSession.data = mockResponse.data(using: .utf8)
        mockSession.response = HTTPURLResponse(
            url: URL(string: "https://api.crossref.org")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )

        let work = try await service.getWork(doi: "10.1000/test")
        XCTAssertNotNil(work)
    }

    func testGetWorkNotFound() async throws {
        mockSession.response = HTTPURLResponse(
            url: URL(string: "https://api.crossref.org")!,
            statusCode: 404,
            httpVersion: nil,
            headerFields: nil
        )

        let work = try await service.getWork(doi: "10.1000/nonexistent")
        XCTAssertNil(work)
    }

    func testGetWorkServerError() async {
        mockSession.response = HTTPURLResponse(
            url: URL(string: "https://api.crossref.org")!,
            statusCode: 500,
            httpVersion: nil,
            headerFields: nil
        )

        do {
            _ = try await service.getWork(doi: "10.1000/test")
            XCTFail("Should throw server error")
        } catch CrossRefError.serverError {
            // Expected
        } catch {
            XCTFail("Wrong error type")
        }
    }
}
```

### 3. Integration Tests (Optional, Live API)

Run against actual APIs in CI (with care for rate limits).

```swift
// Example: TransparencyIntegrationTests.swift
final class TransparencyIntegrationTests: XCTestCase {

    var service: TransparencyAnalysisService!

    override func setUp() {
        // Skip if no network or in quick test mode
        guard ProcessInfo.processInfo.environment["RUN_INTEGRATION_TESTS"] == "1" else {
            throw XCTSkip("Integration tests disabled")
        }

        service = TransparencyAnalysisService(
            email: "test@bmlibrarian.org"
        )
    }

    func testAnalyzeRealPMID() async throws {
        // Known vaccine study with good transparency data
        let result = try await service.analyze(pmid: "33301246")

        XCTAssertNotNil(result.title)
        XCTAssertTrue(result.industryFundingDetected)
        XCTAssertGreaterThan(result.transparencyScore, 0)
    }

    func testAnalyzeRealDOI() async throws {
        let result = try await service.analyze(doi: "10.1056/NEJMoa2034577")

        XCTAssertNotNil(result.title)
        XCTAssertTrue(result.dataSourcesUsed.contains("CrossRef"))
    }
}
```

## Mock Helpers

### MockURLSession

```swift
// Tests/BioMedLitTests/Mocks/MockURLSession.swift
class MockURLSession: URLSession {
    var data: Data?
    var response: URLResponse?
    var error: Error?

    override func data(from url: URL) async throws -> (Data, URLResponse) {
        if let error = error {
            throw error
        }
        guard let data = data, let response = response else {
            throw URLError(.unknown)
        }
        return (data, response)
    }

    override func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        if let error = error {
            throw error
        }
        guard let data = data, let response = response else {
            throw URLError(.unknown)
        }
        return (data, response)
    }
}
```

### Test Data Fixtures

```swift
// Tests/BioMedLitTests/Fixtures/TransparencyTestFixtures.swift
enum TransparencyTestFixtures {

    static let industryFunderWork: [String: Any] = [
        "title": ["Industry-Sponsored Trial"],
        "funder": [
            [
                "name": "Pfizer",
                "DOI": "10.13039/100004319",
                "award": ["GRANT123"]
            ]
        ]
    ]

    static let academicFunderWork: [String: Any] = [
        "title": ["NIH-Funded Study"],
        "funder": [
            [
                "name": "National Institutes of Health",
                "award": ["R01-12345"]
            ]
        ]
    ]

    static let industryTrialStudy: [String: Any] = [
        "protocolSection": [
            "identificationModule": [
                "nctId": "NCT01234567",
                "officialTitle": "Industry Trial"
            ],
            "sponsorCollaboratorsModule": [
                "leadSponsor": [
                    "name": "Pfizer",
                    "class": "INDUSTRY"
                ]
            ]
        ],
        "hasResults": true
    ]

    static let coiStatementWithTies = """
    Dr. Smith reports personal fees from Pfizer, grants from Novartis,
    and serves on the advisory board for AstraZeneca.
    """

    static let coiStatementNoTies = """
    The authors declare no conflict of interest.
    """

    static let dataAvailabilityOpen = """
    All data are available in the Zenodo repository at
    https://zenodo.org/record/12345 under accession number 12345.
    """

    static let dataAvailabilityRestricted = """
    Data available upon reasonable request from the corresponding author.
    IRB approval required for data access.
    """
}
```

## Test Coverage Targets

| Component | Target | Priority |
|-----------|--------|----------|
| TransparencyModels | 95% | High |
| TransparencyConstants | 100% | High |
| FundingAnalyzer | 95% | High |
| COIAnalyzer | 90% | High |
| DataAvailabilityAnalyzer | 90% | High |
| TrialComplianceAnalyzer | 90% | Medium |
| TransparencyScorer | 95% | High |
| CrossRefService | 80% | Medium |
| ClinicalTrialsService | 80% | Medium |
| TransparencyAnalysisService | 70% | Medium |

## Running Tests

```bash
# Run all transparency tests
swift test --filter Transparency

# Run only unit tests (fast)
swift test --filter "Transparency.*Tests" --skip "Integration"

# Run with code coverage
swift test --enable-code-coverage

# Run integration tests
RUN_INTEGRATION_TESTS=1 swift test --filter TransparencyIntegrationTests
```

## CI Configuration

```yaml
# .github/workflows/test.yml (addition)
transparency-tests:
  runs-on: macos-14
  steps:
    - uses: actions/checkout@v4
    - name: Build
      run: swift build
    - name: Unit Tests
      run: swift test --filter "Transparency.*Tests" --skip "Integration"
    - name: Integration Tests (scheduled only)
      if: github.event_name == 'schedule'
      run: RUN_INTEGRATION_TESTS=1 swift test --filter TransparencyIntegrationTests
      env:
        NCBI_EMAIL: ${{ secrets.NCBI_EMAIL }}
```

## Test Documentation

Each test file should include:
1. Brief description of what's being tested
2. Edge cases covered
3. Any known limitations

```swift
/// Tests for FundingAnalyzer pure functions.
///
/// Coverage:
/// - Known industry funder DOI recognition
/// - Government/academic pattern matching
/// - Corporate suffix detection
/// - Sponsor type determination
/// - Funder deduplication
///
/// Edge cases:
/// - Empty/nil inputs
/// - Mixed case names
/// - Multiple funders with same name
/// - Unknown funders
final class FundingAnalyzerTests: XCTestCase {
    // ...
}
```
