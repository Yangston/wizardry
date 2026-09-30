#!/usr/bin/env python3
"""Require successful native CI for the exact main commit before using signing secrets."""
import json
import os
import sys
from urllib.request import Request, urlopen


def verify(runs, sha):
    matches = [r for r in runs if r.get('head_sha') == sha and r.get('head_branch') == 'main'
               and r.get('event') in ('push', 'workflow_dispatch')]
    if not matches:
        raise ValueError('No Build and test run for this main commit. Run unsigned CI first.')
    latest = max(matches, key=lambda r: r['id'])
    if latest.get('status') != 'completed' or latest.get('conclusion') != 'success':
        raise ValueError('The latest Build and test run for this commit has not passed. Finish or repair it before uploading.')
    return latest['id']


def main():
    if os.environ.get('GITHUB_REF') != 'refs/heads/main':
        raise ValueError('Signed distribution is main-only.')
    repository, sha = os.environ['GITHUB_REPOSITORY'], os.environ['GITHUB_SHA']
    request = Request(f'https://api.github.com/repos/{repository}/actions/workflows/build.yml/runs?head_sha={sha}&per_page=100',
                      headers={'Authorization': 'Bearer ' + os.environ['GH_TOKEN'],
                               'Accept': 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28'})
    with urlopen(request, timeout=30) as response: runs = json.load(response)['workflow_runs']
    run = verify(runs, sha)
    print(f'Validated unsigned CI run {run} for commit {sha[:7]}.')


if __name__ == '__main__':
    try: main()
    except (ValueError, KeyError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
