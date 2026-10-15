#!/usr/bin/env python3
"""Offline regression tests for build-recipe validation, not an Apple build."""
import importlib.util
import pathlib
import subprocess
import sys
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).with_name("build_native_crypto_openssl.py")
SPEC = importlib.util.spec_from_file_location("native_build", SCRIPT)
BUILD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUILD)


class NativeBuildRecipeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="native-recipe-tests-")
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)

    def source(self):
        source = self.root / "approved source with spaces"
        source.mkdir()
        (source / "Configurations").mkdir()
        # Minimal synthetic inputs only. Configure is never executed by these tests.
        (source / "Configure").write_text("die 'MUST NOT EXECUTE';\n")
        (source / "VERSION.dat").write_text("MAJOR=3\nMINOR=5\nPATCH=7\n")
        (source / "LICENSE.txt").write_text("Synthetic test notice\n")
        (source / "Configurations/15-ios.conf").write_text("Synthetic test targets\n")
        return source

    def invoke(self, source, *args):
        return subprocess.run([sys.executable, str(SCRIPT), "--source", str(source), *args],
                              capture_output=True, text=True)

    def test_hash_is_stable_and_tracks_source_changes(self):
        source = self.source()
        first, entries = BUILD.source_manifest(source)
        second, _ = BUILD.source_manifest(source)
        self.assertEqual(first, second)
        self.assertEqual(len(entries), 4)
        (source / ".git").mkdir()
        (source / ".git/config").write_text("ignored metadata")
        self.assertEqual(first, BUILD.source_manifest(source)[0])
        (source / "LICENSE.txt").write_text("Changed notice\n")
        self.assertNotEqual(first, BUILD.source_manifest(source)[0])

    def test_hash_only_supports_paths_with_spaces(self):
        source = self.source()
        result = self.invoke(source, "--print-source-sha256")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), BUILD.source_manifest(source)[0])

    def test_unapproved_digest_fails_before_execution_or_output(self):
        source = self.source()
        destination = self.root / "new output"
        result = self.invoke(source, "--source-sha256", "0" * 64,
                             "--mode", "ios", "--output", str(destination))
        self.assertEqual(result.returncode, 2)
        self.assertIn("SHA-256 mismatch", result.stderr)
        self.assertFalse(destination.exists())

    def test_wrong_version_fails(self):
        source = self.source()
        (source / "VERSION.dat").write_text("MAJOR=3\nMINOR=6\nPATCH=4\n")
        result = self.invoke(source, "--print-source-sha256")
        self.assertEqual(result.returncode, 2)
        self.assertIn("requires OpenSSL 3.5.7", result.stderr)

    def test_prerelease_source_fails(self):
        source = self.source()
        with (source / "VERSION.dat").open("a") as stream:
            stream.write("PRE_RELEASE_TAG=dev\n")
        result = self.invoke(source, "--print-source-sha256")
        self.assertEqual(result.returncode, 2)
        self.assertIn("PRE_RELEASE_TAG is nonempty", result.stderr)

    def test_configured_source_fails(self):
        source = self.source()
        (source / "configdata.pm").write_text("already configured")
        result = self.invoke(source, "--print-source-sha256")
        self.assertEqual(result.returncode, 2)
        self.assertIn("pristine", result.stderr)

    def test_source_symlink_fails(self):
        source = self.source()
        (source / "unsafe-link").symlink_to(source / "LICENSE.txt")
        with self.assertRaisesRegex(ValueError, "symlink"):
            BUILD.source_manifest(source)

    def test_notices_preserved_at_original_relative_paths(self):
        source = self.source()
        nested = source / "third_party"
        nested.mkdir()
        (nested / "NOTICE").write_text("nested notice")
        target = self.root / "notices"
        BUILD.preserve_notices(source, target)
        self.assertEqual((target / "LICENSE.txt").read_bytes(), (source / "LICENSE.txt").read_bytes())
        self.assertEqual((target / "third_party/NOTICE").read_text(), "nested notice")

    def headers(self):
        roots = [self.root / name for name in ("arm headers", "x86 headers")]
        for root in roots:
            (root / "openssl").mkdir(parents=True)
            (root / "openssl/crypto.h").write_text("same public header")
            (root / "module.modulemap").write_text(BUILD.MODULE_MAP)
        return roots

    def test_arch_config_is_dispatched_and_originals_preserved(self):
        arm, x86 = self.headers()
        (arm / "openssl/configuration.h").write_text("arm config")
        (x86 / "openssl/configuration.h").write_text("x86 config")
        target = self.root / "merged headers"
        BUILD.merge_simulator_headers(arm, x86, target)
        self.assertEqual((target / "openssl/leap-arch/arm64/configuration.h").read_text(), "arm config")
        self.assertEqual((target / "openssl/leap-arch/x86_64/configuration.h").read_text(), "x86 config")
        self.assertIn("#error Unsupported simulator architecture", (target / "openssl/configuration.h").read_text())

    def test_unexpected_header_difference_fails(self):
        arm, x86 = self.headers()
        (x86 / "openssl/crypto.h").write_text("different API")
        with self.assertRaisesRegex(ValueError, "Unexpected architecture-dependent"):
            BUILD.merge_simulator_headers(arm, x86, self.root / "merged")

    def test_mismatched_header_sets_fail(self):
        arm, x86 = self.headers()
        (x86 / "openssl/extra.h").write_text("extra API")
        with self.assertRaisesRegex(ValueError, "header sets differ"):
            BUILD.merge_simulator_headers(arm, x86, self.root / "merged")


if __name__ == "__main__":
    unittest.main()
