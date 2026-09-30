from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from check_release import verify


class ReleaseGateTests(unittest.TestCase):
    def run_record(self, **changes):
        return {'id': 1, 'head_sha': 'current', 'head_branch': 'main', 'event': 'push',
                'status': 'completed', 'conclusion': 'success', **changes}

    def test_only_exact_successful_main_commit_passes(self):
        self.assertEqual(verify([self.run_record()], 'current'), 1)
        for changes in ({'head_sha': 'older'}, {'head_branch': 'feature'}, {'event': 'pull_request'},
                        {'status': 'in_progress'}, {'conclusion': 'failure'}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                verify([self.run_record(**changes)], 'current')

    def test_new_failed_run_is_not_hidden_by_old_success(self):
        with self.assertRaises(ValueError):
            verify([self.run_record(), self.run_record(id=2, conclusion='failure')], 'current')


if __name__ == '__main__': unittest.main()
