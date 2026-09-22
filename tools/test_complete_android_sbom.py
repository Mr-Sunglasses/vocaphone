import hashlib
import io
import unittest
import zipfile

from complete_android_sbom import complete


class InventoryTests(unittest.TestCase):
    def test_native_hashes_scope_and_unmapped_files(self):
        apk = io.BytesIO()
        with zipfile.ZipFile(apk, 'w') as archive:
            archive.writestr('lib/arm64-v8a/libwhisper.so', b'test-library')
            archive.writestr('lib/arm64-v8a/libother.so', b'other-library')
            archive.writestr('assets/not-a-model.txt', b'not-native')
        bom = {'metadata': {'component': {'bom-ref': 'app'}}, 'components': [],
               'dependencies': [{'ref': 'app', 'dependsOn': []}]}
        result = complete(bom, apk, {}, 'a' * 40)
        components = {item['name']: item for item in result['components']}
        self.assertEqual(len(components), 2)
        whisper = components['lib/arm64-v8a/libwhisper.so']
        self.assertEqual(whisper['hashes'][0]['content'], hashlib.sha256(b'test-library').hexdigest())
        self.assertEqual(whisper['version'], 'a' * 40)
        self.assertEqual(len(result['dependencies'][0]['dependsOn']), 2)
        self.assertIn('not independently mapped', components['lib/arm64-v8a/libother.so']['properties'][0]['value'])


if __name__ == '__main__':
    unittest.main()
