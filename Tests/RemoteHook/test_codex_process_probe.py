import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

source = Path(__file__).parents[2] / 'Sources/CodeIsland/Resources/codex-process-probe.py'
spec = importlib.util.spec_from_file_location('probe', source)
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class CodexProcessProbeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.live = '/home/me/.codex/sessions/live.jsonl'
        self.ended = '/home/me/.codex/sessions/ended.jsonl'

    def process(self, pid, executable, paths):
        folder = self.root / str(pid)
        (folder / 'fd').mkdir(parents=True)
        (folder / 'comm').write_text(Path(executable).name.removesuffix(' (deleted)') + '\n')
        (folder / 'exe').symlink_to(executable)
        for index, path in enumerate(paths):
            (folder / 'fd' / str(index)).symlink_to(path)

    def testExitedCLIIsAbsentEvenWhenAnotherCodexProcessIsAlive(self):
        self.process(10, '/opt/bin/codex', [self.live])
        self.process(11, '/opt/bin/codex', [])
        self.assertEqual(probe.live_transcripts([self.live, self.ended], self.root), [self.live])

    def testLongSilentRolloutIsLiveWithoutReadingItsContentsOrModificationTime(self):
        self.process(10, '/opt/bin/codex', [self.live])
        self.assertEqual(probe.live_transcripts([self.live], self.root), [self.live])

    def testOtherProgramsHoldingTheFileAreNotCodexOwners(self):
        self.process(10, '/usr/bin/tail', [self.ended])
        self.assertEqual(probe.live_transcripts([self.ended], self.root), [])

    def testDeletedExecutableStillCountsAsLive(self):
        self.process(10, '/opt/bin/codex (deleted)', [self.live])
        self.assertEqual(probe.live_transcripts([self.live], self.root), [self.live])

    def testProtectedUnrelatedProcessDoesNotMakeTheCheckUnavailable(self):
        self.process(10, '/usr/bin/sshd', [])
        self.process(11, '/opt/bin/codex', [self.live])
        original = os.readlink

        def denied(path):
            if str(path).endswith('/10/exe'):
                raise PermissionError('setuid sshd')
            return original(path)

        with patch.object(probe.os, 'readlink', side_effect=denied):
            self.assertEqual(probe.live_transcripts([self.live, self.ended], self.root), [self.live])

    def testExecutableIdentifiesCodexEvenIfItsProcessNameChanged(self):
        self.process(10, '/opt/bin/codex', [self.live])
        (self.root / '10/comm').write_text('worker\n')
        self.assertEqual(probe.live_transcripts([self.live], self.root), [self.live])

    def testUnsupportedHostReturnsUnknown(self):
        self.assertIsNone(probe.live_transcripts([self.ended], self.root / 'no-proc'))

    def testPermissionErrorReturnsUnknownRatherThanExited(self):
        self.process(10, '/opt/bin/codex', [self.live])
        original = os.listdir

        def denied(path):
            if str(path).endswith('/fd'):
                raise PermissionError('denied')
            return original(path)

        with patch.object(probe.os, 'listdir', side_effect=denied):
            self.assertIsNone(probe.live_transcripts([self.ended], self.root))

    def testClosingDescriptorDuringEnumerationIsSafe(self):
        self.process(10, '/opt/bin/codex', [self.live])
        original = os.readlink

        def closed(path):
            if str(path).endswith('/fd/0'):
                raise FileNotFoundError('closed')
            return original(path)

        with patch.object(probe.os, 'readlink', side_effect=closed):
            self.assertEqual(probe.live_transcripts([self.live], self.root), [])


if __name__ == '__main__':
    unittest.main()
