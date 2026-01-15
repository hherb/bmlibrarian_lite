package com.bmlibrarian.factchecker

import android.app.Application
import android.content.Context
import androidx.test.runner.AndroidJUnitRunner
import dagger.hilt.android.testing.HiltTestApplication

/**
 * Custom test runner that uses HiltTestApplication for Hilt DI in tests.
 *
 * This runner must be specified in build.gradle.kts:
 * testInstrumentationRunner = "com.bmlibrarian.factchecker.HiltTestRunner"
 */
class HiltTestRunner : AndroidJUnitRunner() {

    override fun newApplication(
        cl: ClassLoader?,
        className: String?,
        context: Context?
    ): Application {
        return super.newApplication(cl, HiltTestApplication::class.java.name, context)
    }
}
