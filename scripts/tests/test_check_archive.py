from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest


class AutorotationArchiveTests(unittest.TestCase):
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

    def test_paired_archive_without_runtime_capability_passes(self):
        for modes in [None, []]:
            with self.subTest(modes=modes):
                result = self.check_archive(modes)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_previous_runtime_experiment_cannot_ship_in_autorotation_build(self):
        for modes in [['self-care'], ['mindfulness']]:
            with self.subTest(modes=modes):
                result = self.check_archive(modes)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Autorotation experiment must not request background runtime', result.stderr)


if __name__ == '__main__':
    unittest.main()
