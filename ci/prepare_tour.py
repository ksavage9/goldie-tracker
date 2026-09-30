"""Copies the app's sources and assets into the UI tour's Xcode project."""
import pathlib
import shutil

app = pathlib.Path("GoldieTracker.swiftpm")
target = pathlib.Path("ci/tour/App")
shutil.rmtree(target, ignore_errors=True)
target.mkdir(parents=True)
for source in sorted(app.glob("*.swift")):
    if source.name != "Package.swift":
        shutil.copy(source, target / source.name)
shutil.copytree(app / "Assets.xcassets", target / "Assets.xcassets")
print("copied", sorted(p.name for p in target.iterdir()))
