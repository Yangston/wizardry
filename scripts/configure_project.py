"""Set the distribution bundle prefix before Xcode resolves signing identities."""
import os
import pathlib
import re

bundle = os.environ.get("BUNDLE_ID", "com.yangston.wizardry")
if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", bundle):
    raise SystemExit("BUNDLE_ID must be a reverse-DNS identifier")
path = pathlib.Path("project.yml")
text, count = re.subn(r"(?m)^    WIZARDRY_BUNDLE_ID: .+$", f"    WIZARDRY_BUNDLE_ID: {bundle}", path.read_text())
if count != 1:
    raise SystemExit("Expected exactly one WIZARDRY_BUNDLE_ID setting")
path.write_text(text)
