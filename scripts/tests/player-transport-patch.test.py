"""Private SDK patch installer checks; no installed SDK or user data touched."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'apply-player-transport-patch.sh'


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.repo = self.root / 'repo'
        (self.repo / 'scripts').mkdir(parents=True)
        (self.repo / 'patches').mkdir()
        self.script = self.repo / 'scripts' / SCRIPT.name
        shutil.copyfile(SCRIPT, self.script)
        self.source = self.root / 'installed-sdk'
        (self.source / 'src').mkdir(parents=True)
        (self.source / 'package.json').write_text(json.dumps({'name': '@native-sdk/cli', 'version': '0.10.1'}))
        (self.source / 'src/sample.zig').write_text('old\n')
        patch = '--- a/src/sample.zig\n+++ b/src/sample.zig\n@@ -1 +1 @@\n-old\n+new\n'
        (self.repo / 'patches/native-sdk-player-transport.patch').write_text(patch)
        manifest = {'version': '0.10.1', 'files': [{'path': 'src/sample.zig',
            'before': hashlib.sha256(b'old\n').hexdigest(), 'after': hashlib.sha256(b'new\n').hexdigest()}]}
        (self.repo / 'patches/native-sdk-player-transport.json').write_text(json.dumps(manifest))
        self.target = self.root / 'private-sdk'

    def run_installer(self, *args):
        return subprocess.run(['bash', str(self.script), '--sdk-path', str(self.target), *args], capture_output=True, text=True)

    def prepare(self):
        result = self.run_installer('--prepare-from', str(self.source))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_prepare_apply_and_idempotent_check_preserve_source(self):
        self.prepare()
        self.assertEqual((self.target / 'src/sample.zig').read_text(), 'new\n')
        self.assertEqual((self.source / 'src/sample.zig').read_text(), 'old\n')
        self.assertEqual(self.run_installer('--check').returncode, 0)
        self.assertEqual(self.run_installer().returncode, 0)

    def test_modified_sdk_is_rejected_without_overwrite(self):
        self.prepare()
        path = self.target / 'src/sample.zig'
        path.write_text('local changes\n')
        self.assertNotEqual(self.run_installer().returncode, 0)
        self.assertEqual(path.read_text(), 'local changes\n')

    def test_installed_sdk_without_private_marker_is_rejected(self):
        self.target = self.source
        self.assertNotEqual(self.run_installer().returncode, 0)
        self.assertEqual((self.source / 'src/sample.zig').read_text(), 'old\n')

    def test_symlink_to_installed_source_is_rejected(self):
        self.prepare()
        path = self.target / 'src/sample.zig'
        path.unlink()
        path.symlink_to(self.source / 'src/sample.zig')
        self.assertNotEqual(self.run_installer().returncode, 0)
        self.assertEqual((self.source / 'src/sample.zig').read_text(), 'old\n')

    def test_prepare_refuses_existing_directory(self):
        self.target.mkdir()
        (self.target / 'keep').write_text('unrelated')
        self.assertNotEqual(self.run_installer('--prepare-from', str(self.source)).returncode, 0)
        self.assertEqual((self.target / 'keep').read_text(), 'unrelated')

    def test_failed_post_apply_verification_rolls_back(self):
        path = self.repo / 'patches/native-sdk-player-transport.json'
        manifest = json.loads(path.read_text())
        manifest['files'][0]['after'] = 'incorrect-hash'
        path.write_text(json.dumps(manifest))
        self.assertNotEqual(self.run_installer('--prepare-from', str(self.source)).returncode, 0)
        self.assertEqual((self.target / 'src/sample.zig').read_text(), 'old\n')


if __name__ == '__main__':
    unittest.main()
