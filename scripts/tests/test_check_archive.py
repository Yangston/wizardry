from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest


class InteractionRuntimeArchiveTests(unittest.TestCase):
    def check_archive(self, modes):
        # Validate the built-plist gate using a minimal paired archive fixture;
        # this does not substitute for compiling or running the native app.
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory)
            phone = archive / 'Products/Applications/Wizardry.app'
            watch = phone / 'Watch/Wizardry.app'
            watch.mkdir(parents=True)
            common = {
                'CFBundleExecutable': 'Wizardry',
                'CFBundleVersion': '1',
                'CFBundleShortVersionString': '0.2.0',
                'NSMotionUsageDescription': 'Motion controls',
                'NSLocalNetworkUsageDescription': 'Computer controls',
            }
            phone_info = {
                **common,
                'CFBundleIdentifier': 'test.wizardry',
                'NSHomeKitUsageDescription': 'Selected home controls',
            }
            watch_info = {
                **common,
                'CFBundleIdentifier': 'test.wizardry.watchkitapp',
                'WKApplication': True,
                'WKCompanionAppBundleIdentifier': 'test.wizardry',
            }
            if modes is not None:
                watch_info['WKBackgroundModes'] = modes
            for app, info in [(phone, phone_info), (watch, watch_info)]:
                (app / 'Wizardry').touch()
                (app / 'Info.plist').write_bytes(plistlib.dumps(info))
            return subprocess.run(
                [sys.executable, str(Path(__file__).resolve().parents[1] / 'check_archive.py'), str(archive)],
                capture_output=True, text=True, check=False,
            )

    def test_paired_archive_with_interaction_runtime_passes(self):
        result = self.check_archive(['self-care'])
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_missing_or_wrong_runtime_declaration_fails(self):
        for modes in [None, [], ['mindfulness']]:
            with self.subTest(modes=modes):
                result = self.check_archive(modes)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Missing experimental interaction runtime capability', result.stderr)


if __name__ == '__main__':
    unittest.main()
