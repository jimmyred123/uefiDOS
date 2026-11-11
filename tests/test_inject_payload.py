import unittest
import os
import tempfile
import shutil
from scripts.inject_payload import (
    get_plain_and_injected_paths,
    prepare_artifact_for_injection,
    finalize_injected_artifact,
)

class TestInjectPayloadDuplication(unittest.TestCase):
    def test_path_derivation(self):
        # ISO
        plain, inj = get_plain_and_injected_paths("/tmp/artifacts/uefiDOS.iso")
        self.assertTrue(plain.endswith("uefiDOS-plain.iso"))
        self.assertTrue(inj.endswith("uefiDOS-injected.iso"))

        # USB img
        plain, inj = get_plain_and_injected_paths("/tmp/artifacts/uefiDOS-usb.img")
        self.assertTrue(plain.endswith("uefiDOS-plain-usb.img"))
        self.assertTrue(inj.endswith("uefiDOS-injected-usb.img"))

        # USB zip
        plain, inj = get_plain_and_injected_paths("/tmp/artifacts/uefiDOS-usb-files.zip")
        self.assertTrue(plain.endswith("uefiDOS-plain-usb-files.zip"))
        self.assertTrue(inj.endswith("uefiDOS-injected-usb-files.zip"))

    def test_preservation_and_duplication_lifecycle(self):
        with tempfile.TemporaryDirectory() as td:
            target_iso = os.path.join(td, "uefiDOS.iso")
            with open(target_iso, "wb") as f:
                f.write(b"PRISTINE_BASE_DATA")

            # 1. First preparation: should create -plain copy
            plain_path, inj_path = prepare_artifact_for_injection(target_iso, duplicate=True)
            self.assertTrue(os.path.exists(plain_path))
            with open(plain_path, "rb") as f:
                self.assertEqual(f.read(), b"PRISTINE_BASE_DATA")

            # Simulate injection modifying target_iso
            with open(target_iso, "wb") as f:
                f.write(b"INJECTED_PAYLOAD_DATA")

            # Finalize: should create -injected copy
            finalize_injected_artifact(target_iso, inj_path, duplicate=True)
            self.assertTrue(os.path.exists(inj_path))
            with open(inj_path, "rb") as f:
                self.assertEqual(f.read(), b"INJECTED_PAYLOAD_DATA")

            # 2. Second preparation (re-injection): should restore from pristine -plain copy
            prepare_artifact_for_injection(target_iso, duplicate=True)
            with open(target_iso, "rb") as f:
                self.assertEqual(f.read(), b"PRISTINE_BASE_DATA", "Must restore to pristine baseline from -plain")

if __name__ == "__main__":
    unittest.main()
