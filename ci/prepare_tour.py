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

# Swift Playgrounds sets the accent from Package.swift (.presetColor(.orange)); an Xcode project needs a color asset.
accent = target / "Assets.xcassets" / "AccentColor.colorset"
accent.mkdir()
(accent / "Contents.json").write_text(
    '{"colors":[{"idiom":"universal","color":{"platform":"ios","reference":"systemOrangeColor"}}],'
    '"info":{"author":"xcode","version":1}}'
)
print("copied", sorted(p.name for p in target.iterdir()))
