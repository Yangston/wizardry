"""Print only missing configuration names, never secret values."""
import os
import sys

required = ["APP_STORE_CONNECT_ISSUER_ID", "APP_STORE_CONNECT_KEY_IDENTIFIER",
            "APP_STORE_CONNECT_PRIVATE_KEY", "CERTIFICATE_PRIVATE_KEY",
            "APPLE_TEAM_ID", "APP_STORE_APP_ID"]
missing = [name for name in required if not os.environ.get(name, "").strip()]
if missing:
    print("Configure GitHub repository secrets/variables first. See docs/SETUP.md.")
    print("Missing: " + ", ".join(missing))
    sys.exit(1)
print("Required configuration is present.")
