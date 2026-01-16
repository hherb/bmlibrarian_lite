# Developer Quick Start Guide

This guide helps developers set up their environment and start contributing to the Medical Fact Checker Android app.

## Prerequisites

### Required Software

1. **Android Studio** (Hedgehog 2023.1.1 or later)
   - Download: https://developer.android.com/studio
   - Includes Android SDK, Gradle, and emulator

2. **Java Development Kit 17**
   - Android Studio includes a bundled JDK
   - Or install separately: https://adoptium.net/

3. **Git**
   - Download: https://git-scm.com/

### Recommended

- Physical Android device for testing (API 26+)
- API keys for at least one LLM provider

## Environment Setup

### 1. Clone the Repository

```bash
git clone https://github.com/hherb/bmlibrarian_lite.git
cd bmlibrarian_lite/android/MedicalFactChecker
```

### 2. Open in Android Studio

1. Launch Android Studio
2. Select **File → Open**
3. Navigate to `bmlibrarian_lite/android/MedicalFactChecker`
4. Click **Open**
5. Wait for Gradle sync to complete (first sync may take several minutes)

### 3. Configure SDK

If prompted, install the required SDK components:
- Android SDK 34 (Compile SDK)
- Android SDK 26 (Min SDK for testing)
- Build Tools 34.x

### 4. Create an Emulator (Optional)

1. **Tools → Device Manager**
2. Click **Create Device**
3. Select a device (e.g., Pixel 7)
4. Select a system image (API 34 recommended)
5. Finish setup

## Project Structure

```
MedicalFactChecker/
├── app/
│   ├── src/
│   │   ├── main/
│   │   │   ├── java/com/bmlibrarian/factchecker/
│   │   │   │   ├── data/           # Data layer
│   │   │   │   │   ├── local/      # Room database
│   │   │   │   │   ├── remote/     # API clients
│   │   │   │   │   └── repository/ # Repositories
│   │   │   │   ├── domain/         # Business logic
│   │   │   │   │   ├── model/      # Domain models
│   │   │   │   │   └── workflow/   # Workflow engine
│   │   │   │   ├── ui/             # Compose UI
│   │   │   │   │   ├── factcheck/
│   │   │   │   │   ├── report/
│   │   │   │   │   ├── history/
│   │   │   │   │   ├── settings/
│   │   │   │   │   └── navigation/
│   │   │   │   ├── di/             # Hilt modules
│   │   │   │   └── util/           # Utilities
│   │   │   └── res/                # Resources
│   │   ├── test/                   # Unit tests
│   │   └── androidTest/            # Instrumented tests
│   ├── build.gradle.kts            # App module build config
│   └── proguard-rules.pro          # ProGuard rules
├── build.gradle.kts                # Project build config
├── settings.gradle.kts             # Project settings
├── gradle.properties               # Gradle properties
└── gradle/                         # Gradle wrapper
```

## Building and Running

### Debug Build

```bash
# Command line
./gradlew assembleDebug

# Or in Android Studio: Build → Make Project (Ctrl+F9)
```

### Run on Device/Emulator

```bash
# Command line
./gradlew installDebug

# Or in Android Studio: Run (Shift+F10)
```

### Release Build

```bash
./gradlew assembleRelease
```

Note: Release builds require signing configuration.

## Running Tests

### Unit Tests

```bash
# All unit tests
./gradlew test

# Specific test class
./gradlew test --tests "com.bmlibrarian.factchecker.util.CostCalculatorTest"

# With coverage report
./gradlew testDebugUnitTestCoverage
```

### Instrumented Tests

Requires a connected device or running emulator:

```bash
# All instrumented tests
./gradlew connectedAndroidTest

# Specific test
./gradlew connectedAndroidTest -Pandroid.testInstrumentationRunnerArguments.class=com.bmlibrarian.factchecker.data.local.dao.SessionDaoTest
```

### All Tests

```bash
./gradlew check
```

## Code Style Guidelines

### Kotlin Style

Follow the official [Kotlin Coding Conventions](https://kotlinlang.org/docs/coding-conventions.html):

- Use 4 spaces for indentation
- Maximum line length: 120 characters
- Use trailing commas in multi-line declarations

### Documentation Requirements

All public classes, functions, and properties must have KDoc comments:

```kotlin
/**
 * Calculates the cost of an LLM API call.
 *
 * @param modelInfo Model pricing information
 * @param inputTokens Number of input tokens
 * @param outputTokens Number of output tokens
 * @return Total cost in USD
 */
fun calculateCost(modelInfo: ModelInfo, inputTokens: Int, outputTokens: Int): Double
```

### Architecture Guidelines

1. **No Magic Numbers**: Use constants defined in `Constants.kt`
2. **Pure Functions**: Prefer stateless functions over stateful classes
3. **Clean Separation**: Follow the layer boundaries (data → domain → ui)
4. **Dependency Injection**: Use Hilt for all dependencies
5. **Error Handling**: All errors must be caught, logged, and surfaced to the user
6. **Retry Logic**: Network calls must implement exponential backoff

### Testing Requirements

- All public functions must have unit tests
- API services must have mocked tests
- DAOs must have instrumented tests
- Coverage target: 80%+ for new code

## Key Patterns

### ViewModels

```kotlin
@HiltViewModel
class ExampleViewModel @Inject constructor(
    private val repository: ExampleRepository
) : ViewModel() {

    private val _uiState = MutableStateFlow(ExampleUiState())
    val uiState: StateFlow<ExampleUiState> = _uiState.asStateFlow()

    fun doSomething() {
        viewModelScope.launch {
            // Update state
            _uiState.update { it.copy(isLoading = true) }
            // Perform operation
            // Handle result
        }
    }
}
```

### Repository Pattern

```kotlin
class ExampleRepository @Inject constructor(
    private val dao: ExampleDao,
    private val api: ExampleApi
) {
    suspend fun getData(): Result<Data> {
        return try {
            val data = api.fetchData()
            dao.insert(data)
            Result.success(data)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
}
```

### Composables

```kotlin
@Composable
fun ExampleScreen(
    viewModel: ExampleViewModel = hiltViewModel(),
    onNavigate: () -> Unit
) {
    val uiState by viewModel.uiState.collectAsStateWithLifecycle()

    ExampleContent(
        state = uiState,
        onAction = viewModel::handleAction,
        onNavigate = onNavigate
    )
}

@Composable
private fun ExampleContent(
    state: ExampleUiState,
    onAction: (Action) -> Unit,
    onNavigate: () -> Unit
) {
    // UI implementation
}
```

## Common Tasks

### Adding a New Screen

1. Create UI state class in `ui/newscreen/NewScreenUiState.kt`
2. Create ViewModel in `ui/newscreen/NewScreenViewModel.kt`
3. Create Composable in `ui/newscreen/NewScreenScreen.kt`
4. Add route to `navigation/NavRoutes.kt`
5. Add navigation in `navigation/AppNavigation.kt`
6. Add unit tests for ViewModel

### Adding a New API Endpoint

1. Add Retrofit method to appropriate API interface
2. Add models in the corresponding models file
3. Implement in the service class with retry logic
4. Add error handling
5. Add unit tests with mocked responses

### Adding a New Database Entity

1. Create entity in `data/local/entity/`
2. Create DAO in `data/local/dao/`
3. Add DAO to `AppDatabase`
4. Increment database version if migrating
5. Add instrumented tests

## Debugging Tips

### Network Inspection

Use Android Studio's Network Inspector or Charles Proxy to inspect API calls.

### Database Inspection

Use Android Studio's Database Inspector (**View → Tool Windows → App Inspection**).

### Logging

```kotlin
import android.util.Log

Log.d("TAG", "Debug message")
Log.e("TAG", "Error message", exception)
```

## Submitting Changes

### Before Submitting

1. Run all tests: `./gradlew check`
2. Format code: Use Android Studio's **Code → Reformat Code** (Ctrl+Alt+L)
3. Check for warnings: **Analyze → Inspect Code**
4. Update documentation if needed
5. Add/update tests for your changes

### Pull Request Guidelines

1. Create a feature branch: `git checkout -b feature/my-feature`
2. Make focused, atomic commits
3. Write clear commit messages
4. Open PR against the main branch
5. Fill out the PR template
6. Address review comments

## Getting Help

- **Questions**: Open a [GitHub Discussion](https://github.com/hherb/bmlibrarian_lite/discussions)
- **Bugs**: File a [GitHub Issue](https://github.com/hherb/bmlibrarian_lite/issues)
- **Architecture Questions**: Check the main project's `CLAUDE.md` for context

## Useful Links

- [Kotlin Documentation](https://kotlinlang.org/docs/)
- [Jetpack Compose](https://developer.android.com/jetpack/compose)
- [Room Database](https://developer.android.com/training/data-storage/room)
- [Hilt Dependency Injection](https://developer.android.com/training/dependency-injection/hilt-android)
- [Retrofit](https://square.github.io/retrofit/)
- [MockK](https://mockk.io/)
