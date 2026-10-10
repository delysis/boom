#!/usr/bin/env python3
"""Exercise the real collector against exact, missing and mismatched sources."""
import json
import hashlib
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]

class NoticeCollectorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="bloom-notice-tests-")
        cls.base = pathlib.Path(cls.temp.name)
        cls.binary = cls.base / "collector"
        subprocess.run(["swiftc", str(ROOT / "scripts/collect-notices.swift"), "-o", str(cls.binary)], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def setUp(self):
        self.temp_case = tempfile.TemporaryDirectory(dir=self.base)
        self.addCleanup(self.temp_case.cleanup)
        self.root = pathlib.Path(self.temp_case.name)
        self.checkout = self.root / "App/.build/checkouts/library"
        self.runtime = self.root / ".deps/MLXSwiftLM"
        for directory in [self.checkout, self.runtime]:
            directory.mkdir(parents=True)
            (directory / "LICENSE").write_bytes(b"Fixture raw notice\n")
            self.git(directory, "init", "-q")
            self.git(directory, "add", "LICENSE")
            self.git(directory, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture")
        self.revision = self.git(self.checkout, "rev-parse", "HEAD")
        self.runtime_revision = self.git(self.runtime, "rev-parse", "HEAD")
        rust = self.root / "rust"
        rust.mkdir()
        (rust / "LICENSE").write_bytes(b"Rust fixture notice\n")
        self.packages = [{"name": "fixture", "version": "1.0.0", "manifest_path": str(rust / "Cargo.toml"), "license": "MIT"}]
        self.pins = [{"identity": "library", "state": {"revision": self.revision}}]

    def git(self, directory, *args):
        return subprocess.check_output(["git", "-C", str(directory), *args], text=True).strip()

    def collect(self):
        metadata = {"packages": self.packages, **getattr(self, "workspace", {})}
        (self.root / "metadata.json").write_text(json.dumps(metadata))
        (self.root / "App/Package.resolved").write_text(json.dumps({"pins": self.pins}))
        result = subprocess.run([str(self.binary), str(self.root), str(self.root / "metadata.json"),
            str(self.root / "notices"), str(self.root / "inventory.json"), self.runtime_revision], capture_output=True, text=True)
        self.assertTrue((self.root / "inventory.json").exists(), result.stderr)
        return result, json.loads((self.root / "inventory.json").read_text())

    def test_exact_sources_retain_raw_notices_without_approval(self):
        result, record = self.collect()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(record["source_inventory_complete"])
        self.assertTrue(record["notices_complete"])
        self.assertFalse(record["distribution_approved"])
        self.assertEqual(len(record["packages"]), 3)
        for row in record["packages"]:
            self.assertEqual(row["status"], "retained")
            content = (self.root / "notices" / row["retained_notices"][0]).read_bytes()
            self.assertIn(content, [b"Fixture raw notice\n", b"Rust fixture notice\n"])

    def assert_unresolved(self, status):
        result, record = self.collect()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(record["source_inventory_complete"])
        self.assertFalse(record["notices_complete"])
        self.assertFalse(record["distribution_approved"])
        self.assertIn(status, [row["status"] for row in record["packages"]])

    def test_missing_pin_is_retained(self):
        self.pins.append({"identity": "missing", "state": {"revision": self.revision}})
        self.assert_unresolved("missing_checkout")

    def test_wrong_revision_is_rejected(self):
        self.pins[0]["state"]["revision"] = "0" * 40
        self.assert_unresolved("revision_mismatch")

    def test_duplicate_pin_is_rejected(self):
        self.pins.append(self.pins[0])
        self.assert_unresolved("duplicate_pin")

    def test_malformed_cargo_entries_are_retained(self):
        self.packages.extend([{"name": "missing-manifest"}, None])
        self.assert_unresolved("invalid_metadata")

    def test_modified_checkout_is_rejected(self):
        (self.checkout / "LICENSE").write_text("Modified notice")
        self.assert_unresolved("modified_checkout")

    def test_untracked_notice_does_not_borrow_the_pin(self):
        (self.checkout / "NOTICE-extra").write_text("Untracked notice")
        result, record = self.collect()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(record["notices_complete"])
        row = next(row for row in record["packages"] if row["package"] == "swift:library")
        self.assertEqual(row["status"], "notices_incomplete")
        self.assertEqual(row["rejected_notices"], ["NOTICE-extra"])

    def test_missing_notice_is_explicit(self):
        (self.root / "rust/LICENSE").unlink()
        result, record = self.collect()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(record["source_inventory_complete"])
        self.assertFalse(record["notices_complete"])
        self.assertIn("notices_missing", [row["status"] for row in record["packages"]])

    def test_workspace_inheritance_cannot_cover_a_registry_crate(self):
        (self.root / "rust/LICENSE").unlink()
        raw = b"Inherited workspace permission\n"
        (self.root / "LICENSE-MIT").write_bytes(raw)
        self.packages[0].update(id="workspace-member", source=None)
        self.workspace = {"workspace_root": str(self.root), "workspace_members": ["workspace-member"]}
        external = self.root / "registry"
        external.mkdir()
        self.packages.append({"name": "external", "version": "2.0.0", "id": "registry-package",
            "source": "registry+fixture", "manifest_path": str(external / "Cargo.toml"), "license": "MIT"})
        result, record = self.collect()
        self.assertNotEqual(result.returncode, 0)
        member = next(row for row in record["packages"] if row["package"] == "rust:fixture:1.0.0")
        registry = next(row for row in record["packages"] if row["package"] == "rust:external:2.0.0")
        self.assertEqual(member["status"], "retained")
        self.assertEqual((self.root / "notices" / member["retained_notices"][0]).read_bytes(), raw)
        self.assertEqual(registry["status"], "notices_missing")

    def test_directory_licence_and_authors_are_retained_as_raw_bytes(self):
        rust = self.root / "rust"
        (rust / "LICENSE").unlink()
        (rust / "LICENSES").mkdir()
        notices = {"LICENSES/Apache-2.0.txt": b"Apache fixture\n", "LICENSES/MIT.txt": b"MIT fixture\n",
            "LICENCE": b"British spelling\n", "AUTHORS": b"Author permission body\n"}
        for name, raw in notices.items():
            (rust / name).write_bytes(raw)
        result, record = self.collect()
        self.assertEqual(result.returncode, 0, result.stderr)
        row = next(row for row in record["packages"] if row["package"].startswith("rust:"))
        self.assertEqual({(self.root / "notices" / name).read_bytes() for name in row["retained_notices"]}, set(notices.values()))

    def test_license_directory_symlinks_and_nested_directories_are_rejected(self):
        rust = self.root / "rust"
        (rust / "LICENSES").mkdir()
        (rust / "LICENSES/link").symlink_to(rust / "LICENSE")
        (rust / "LICENSES/nested").mkdir()
        (rust / "LICENSES/nested/LICENSE").write_text("Hidden nested notice")
        result, record = self.collect()
        self.assertNotEqual(result.returncode, 0)
        row = next(row for row in record["packages"] if row["package"].startswith("rust:"))
        self.assertEqual(row["status"], "notices_incomplete")
        self.assertEqual(row["rejected_notices"], ["link", "nested"])

    def supplemental(self):
        rust = self.root / "rust"
        (rust / "LICENSE").unlink()
        revision = "1" * 40
        repository = "https://github.com/fixture/repository"
        self.packages[0]["repository"] = repository
        (rust / ".cargo_vcs_info.json").write_text(json.dumps({"git": {"sha1": revision}}))
        raw = b"Exact omitted upstream license\n"
        path = "licenses/fixture-1.0.0/LICENSE"
        (self.root / path).parent.mkdir(parents=True)
        (self.root / path).write_bytes(raw)
        blob = hashlib.sha1(f"blob {len(raw)}\0".encode() + raw).hexdigest()
        manifest = {"schema": 1, "packages": [{"package": "rust:fixture:1.0.0", "revision": revision,
            "repository": repository, "files": [{"path": path, "upstream_path": "LICENSE",
                "git_blob": blob, "sha256": hashlib.sha256(raw).hexdigest()}]}]}
        (self.root / "licenses/supplemental.json").write_text(json.dumps(manifest))
        return path

    def test_supplemental_notice_is_bound_to_source_revision_and_raw_hashes(self):
        path = self.supplemental()
        result, record = self.collect()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(record["notices_complete"])
        row = next(row for row in record["packages"] if row["package"].startswith("rust:"))
        self.assertEqual((self.root / "notices" / row["retained_notices"][0]).read_bytes(), (self.root / path).read_bytes())
        self.assertEqual(row["supplemental_revision"], "1" * 40)

    def test_supplemental_notice_cannot_cover_a_changed_source(self):
        self.supplemental()
        (self.root / "rust/.cargo_vcs_info.json").write_text(json.dumps({"git": {"sha1": "2" * 40}}))
        result, record = self.collect()
        self.assertNotEqual(result.returncode, 0)
        row = next(row for row in record["packages"] if row["package"].startswith("rust:"))
        self.assertEqual(row["status"], "notices_missing")
        self.assertIn("supplemental_source_mismatch", row["rejected_notices"])

    def test_tampered_supplemental_notice_is_rejected(self):
        path = self.supplemental()
        (self.root / path).write_text("Changed raw content")
        result, record = self.collect()
        self.assertNotEqual(result.returncode, 0)
        row = next(row for row in record["packages"] if row["package"].startswith("rust:"))
        self.assertEqual(row["retained_notices"], [])
        self.assertIn(path, row["rejected_notices"])

if __name__ == "__main__":
    unittest.main()
