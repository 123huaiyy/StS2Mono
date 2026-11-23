import hashlib
import io
import struct
import unittest

from package_ios import MONO_PUBLISH_MANIFEST, PACK_ENTRY, PACK_HEADER, read_pack_index, write_pack


class PackageIosTest(unittest.TestCase):
    def test_windows_pack_gets_empty_ios_mono_manifest(self):
        project = b"ECFG" + struct.pack("<I", 0)
        label = b"project.binary\0\0"
        file_base = 112
        index_offset = file_base + len(project)
        header = PACK_HEADER.pack(b"GDPC", 3, 4, 5, 1, 2, file_base, index_offset)
        entry = PACK_ENTRY.pack(0, len(project), hashlib.md5(project).digest(), 0)
        source = io.BytesIO(header.ljust(file_base, b"\0") + project
                            + struct.pack("<II", 1, len(label)) + label + entry)
        packaged = io.BytesIO()

        write_pack(source, packaged, b'{"version":"v0.113.1"}')

        packaged.seek(0)
        _, file_base, index_offset, entries = read_pack_index(packaged)
        offset, size, digest, flags = entries[MONO_PUBLISH_MANIFEST]
        self.assertLessEqual(file_base + offset, index_offset)
        self.assertEqual((size, digest, flags), (0, hashlib.md5(b"").digest(), 0))
        self.assertIn("project.binary", entries)
        self.assertIn("release_info.json", entries)


if __name__ == "__main__":
    unittest.main()
