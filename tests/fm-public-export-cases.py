"""Executable-only export regressions; no live homes, credentials or network."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest

ROOT, TMP = map(Path, sys.argv[1:])
sys.argv[1:] = []


class ExportTests(unittest.TestCase):
    def setUp(self):
        self.area = TMP / self._testMethodName
        self.area.mkdir()
        self.repo = self.area / 'repo with spaces'
        self.repo.mkdir()
        self.env = {k: v for k, v in os.environ.items() if not k.startswith('GIT_')}
        self.env.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull,
                        GIT_AUTHOR_NAME='Fixture', GIT_AUTHOR_EMAIL='fixture@example.invalid',
                        GIT_COMMITTER_NAME='Fixture', GIT_COMMITTER_EMAIL='fixture@example.invalid')
        self.git('init', '-q')
        self.git('config', 'core.hooksPath', os.devnull)
        for file in ['bin/fm-public-export.py', 'docs/public-export-manifest.json']:
            self.put(file, (ROOT / file).read_bytes())
        for file in ['LICENSE', 'AGENTS.md', 'README.md', 'bin/fm-session-start.sh']:
            self.put(file, b'Public fixture\n')
        self.put('docs/removed.md', b'Removed in next release\n')
        self.put('bin/tool.sh', b'#!/bin/sh\nprintf portable\n')
        (self.repo / 'bin/tool.sh').chmod(0o755)
        self.base = self.commit()

    def put(self, path, content):
        file = self.repo / path
        file.parent.mkdir(exist_ok=True, parents=True)
        file.write_bytes(content)

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.repo), *args], env=self.env, stderr=subprocess.PIPE)

    def commit(self):
        self.git('add', '-A')
        self.git('commit', '-qm', 'fixture snapshot', '--allow-empty')
        return self.git('rev-parse', 'HEAD').decode().strip()

    def run_export(self, source=None, extra=()):
        self.out = self.area / 'export'
        return subprocess.run([sys.executable, str(self.repo / 'bin/fm-public-export.py'),
                               '--source', source or self.commit(), '--public-base', self.base,
                               '--output', str(self.out), *extra], env=self.env, capture_output=True)

    def test_patch_tree_modes_and_private_history(self):
        self.put('config/private', b'private configuration')
        self.put('data/report.md', b'private report')
        self.put('state/event', b'private runtime')
        self.put('projects/demo/private', b'private project')
        self.put('.env', b'private credentials')
        self.put('README.md', b'Portable update\n')
        (self.repo / 'docs/removed.md').unlink()
        (self.repo / 'bin/tool-link').symlink_to('tool.sh')
        source = self.commit()
        self.git('branch', 'frozen-private-work')
        # Working overlays/untracked files are deliberately outside the export.
        self.put('AGENTS.md', b'Uncommitted private operator overlay\n')
        self.put('docs/untracked.md', b'private working note')
        before = self.git('status', '--porcelain=v1')
        refs = self.git('show-ref')
        result = self.run_export(source)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        receipt = json.loads((self.out / 'receipt.json').read_text())
        self.assertEqual(receipt['source_commit'], source)
        self.assertFalse(receipt['history_exported'])
        self.assertEqual(len(receipt['excluded']), 5)
        self.assertEqual((self.out / 'tree/AGENTS.md').read_bytes(), b'Public fixture\n')
        self.assertFalse((self.out / 'tree/docs/untracked.md').exists())
        self.assertFalse((self.out / 'tree/.git').exists())
        self.assertEqual(before, self.git('status', '--porcelain=v1'))
        self.assertEqual(refs, self.git('show-ref'))
        # Reconstruct exactly from only the public base and exported patch.
        index = self.area / 'public-index'
        env = dict(self.env, GIT_INDEX_FILE=str(index))
        def public_git(*args):
            return subprocess.check_output(['git', '-C', str(self.repo), *args], env=env, stderr=subprocess.PIPE)
        public_git('read-tree', self.base)
        public_git('apply', '--cached', '--check', str(self.out / 'changes.patch'))
        public_git('apply', '--cached', str(self.out / 'changes.patch'))
        self.assertEqual(public_git('write-tree').decode().strip(), receipt['public_tree'])
        self.assertEqual(hashlib.sha256((self.out / 'changes.patch').read_bytes()).hexdigest(), receipt['patch_sha256'])
        self.assertTrue(os.access(self.out / 'tree/bin/tool.sh', os.X_OK))
        self.assertTrue((self.out / 'tree/bin/tool-link').is_symlink())

    def test_managed_overlay_export_only(self):
        self.put('AGENTS.md', b'<!-- private-extension:managed:start -->\nprivate overlay\n<!-- private-extension:managed:end -->\nPublic fixture\n')
        result = self.run_export()
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertNotIn(b'private overlay', (self.out / 'tree/AGENTS.md').read_bytes())
        self.assertIn(b'private overlay', (self.repo / 'AGENTS.md').read_bytes())
        self.assertEqual(json.loads((self.out / 'receipt.json').read_text())['sanitized'][0]['count'], 1)

    def test_private_path_refuses_without_echoing_value(self):
        value = b'/home/' + b'private-person/private-project'
        self.put('bin/leak.txt', value)
        result = self.run_export()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b'user-path', result.stdout)
        self.assertNotIn(value, result.stdout + result.stderr)
        self.assertFalse(self.out.exists())

    def test_private_literal_deny_list(self):
        value = b'confidential' + b'-project-identifier'
        deny = self.area / 'deny'
        deny.write_bytes(value + b'\n')
        self.put('docs/new.md', value)
        result = self.run_export(extra=('--deny-file', str(deny)))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b'private-deny-list', result.stdout)
        self.assertNotIn(value, result.stdout)

    def test_escape_link_unknown_file_and_binary_refuse(self):
        (self.repo / 'bin/escape').symlink_to('../../outside')
        self.put('personal-notes.txt', b'private')
        self.put('assets/new.png', b'\x89PNG\0private')
        result = self.run_export()
        self.assertNotEqual(result.returncode, 0)
        for category in [b'escaping-link', b'unlisted-path', b'new-binary']:
            self.assertIn(category, result.stdout)
        self.assertFalse(self.out.exists())

    def test_public_examples_preserved_but_new_count_refuses(self):
        example = b'/home/' + b'example/project'
        self.put('docs/example.md', example)
        self.base = self.commit()
        self.put('docs/example.md', example + b'\n' + example)
        result = self.run_export()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b'user-path', result.stdout)

    def test_existing_destination_and_symbolic_source_refuse(self):
        self.out = self.area / 'export'
        self.out.mkdir()
        (self.out / 'sentinel').write_text('preserve')
        result = self.run_export()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.out / 'sentinel').read_text(), 'preserve')
        result = self.run_export('HEAD')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b'full commit IDs', result.stderr)


unittest.main()
