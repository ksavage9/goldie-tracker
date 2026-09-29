"""Copies the app's source files into the test package, so the tests exercise the exact code that ships."""
import pathlib
import shutil

app = pathlib.Path("GoldieTracker.swiftpm")
target = pathlib.Path("Verification/Sources/GoldieCore")
skip = {"Package.swift", "GoldieTrackerApp.swift"}  # the package manifest and the @main entry point
for source in sorted(app.glob("*.swift")):
    if source.name not in skip:
        shutil.copy(source, target / source.name)
        print("copied", source.name)
