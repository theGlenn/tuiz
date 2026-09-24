"""Exercise terminal lifecycle in child processes; never change the runner's TTY."""

import os
import pty
import select
import signal
import subprocess
import sys
import termios
import unittest


PROBE = sys.argv.pop(1)


class TerminalTests(unittest.TestCase):
    def drain(self, source):
        subprocess.run([PROBE, "drain"], stdin=source, check=True, timeout=3)

    def test_dev_null_eof(self):
        with open(os.devnull, "rb") as source:
            self.drain(source)

    def test_exhausted_pipe(self):
        subprocess.run([PROBE, "drain"], input=b"type-ahead", check=True, timeout=3)

    def test_pty_hangup(self):
        master, slave = pty.openpty()
        os.close(master)
        try:
            self.drain(slave)
        finally:
            os.close(slave)

    def test_raw_mode_resize_and_restoration(self):
        master, slave = pty.openpty()
        original = termios.tcgetattr(slave)
        try:
            with subprocess.Popen(
                [PROBE, "raw"], stdin=slave, stdout=subprocess.PIPE, stderr=subprocess.PIPE
            ) as proc:
                try:
                    self.assertTrue(select.select([proc.stdout], [], [], 3)[0], "probe did not start")
                    self.assertEqual(proc.stdout.readline(), b"ready\n")
                    raw = termios.tcgetattr(slave)
                    self.assertEqual(raw[3] & (termios.ECHO | termios.ICANON | termios.ISIG), 0)
                    os.kill(proc.pid, signal.SIGWINCH)
                    os.write(master, b"q")
                    _, stderr = proc.communicate(timeout=3)
                    self.assertEqual(proc.returncode, 0, stderr.decode())
                finally:
                    if proc.poll() is None:
                        proc.kill()
                        proc.communicate()
            self.assertEqual(termios.tcgetattr(slave), original)
        finally:
            os.close(master)
            os.close(slave)


if __name__ == "__main__":
    unittest.main()
