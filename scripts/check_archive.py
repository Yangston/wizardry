"""Fail early when the archive is not packaged as a paired iPhone and Watch app."""
import pathlib
import plistlib
import sys

archive = pathlib.Path(sys.argv[1])
apps = list((archive / "Products/Applications").glob("*.app"))
assert len(apps) == 1, f"Expected one distribution container, found {apps}"
with (apps[0] / "Info.plist").open("rb") as source:
    container = plistlib.load(source)
assert not container.get("ITSWatchOnlyContainer"), "Expected a launchable iPhone companion"
assert not container.get("LSApplicationLaunchProhibited"), "iPhone launch is prohibited"
assert (apps[0] / container["CFBundleExecutable"]).is_file(), "Missing iPhone executable"
assert container.get("NSHomeKitUsageDescription"), "Missing Home permission description"
watches = list((apps[0] / "Watch").glob("*.app"))
assert len(watches) == 1, f"Expected Watch/*.app inside container, found {watches}"
with (watches[0] / "Info.plist").open("rb") as source:
    watch = plistlib.load(source)
assert watch.get("WKApplication") and not watch.get("WKWatchOnly"), "Expected a companion watch app"
assert watch.get("WKCompanionAppBundleIdentifier") == container["CFBundleIdentifier"], "Watch companion ID mismatch"
assert (watches[0] / watch["CFBundleExecutable"]).is_file(), "Missing watch executable"
assert watch["CFBundleIdentifier"].startswith(container["CFBundleIdentifier"] + ".")
assert watch["CFBundleVersion"] == container["CFBundleVersion"], (
    f"Build numbers must match: watch={watch['CFBundleVersion']!r}, container={container['CFBundleVersion']!r}"
)
assert watch["CFBundleShortVersionString"] == container["CFBundleShortVersionString"], "Release versions must match"
for name, info in (("container", container), ("watch", watch)):
    assert info.get("NSMotionUsageDescription", "").strip(), f"Missing motion purpose in {name}"
    assert info.get("NSLocalNetworkUsageDescription", "").strip(), f"Missing local network purpose in {name}"
print("Paired iPhone and Watch archive structure and versions verified.")
