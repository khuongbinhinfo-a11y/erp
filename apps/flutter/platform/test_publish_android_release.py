"""R2 release unit tests: the fake object store never uses real credentials."""
import hashlib
import io
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock
from botocore.exceptions import ClientError
import publish_android_release as publisher

class FakeR2:
    def __init__(self):
        self.objects = {}
        self.inject = {}
    def _error(self, name):
        raise ClientError({'Error': {'Code': name, 'Message': name}}, 'PutObject')
    def get_object(self, *, Bucket, Key):
        obj = self.objects.get(Key)
        if obj is None:
            self._error('NoSuchKey')
        return {'Body': io.BytesIO(obj), 'ETag': '"' + hashlib.md5(obj).hexdigest() + '"'}
    def put_object(self, *, Bucket, Key, Body, IfNoneMatch=None, IfMatch=None, **kwargs):
        previous = self.objects.get(Key)
        etag = None if previous is None else '"' + hashlib.md5(previous).hexdigest() + '"'
        if (IfNoneMatch and previous is not None) or (IfMatch is not None and etag != IfMatch):
            self._error('PreconditionFailed')
        data = Body.read() if hasattr(Body, 'read') else Body
        self.objects[Key] = data
        if self.inject.pop(Key, None) == 'after':
            raise TimeoutError('simulated timeout after COMMIT')
        return {'ETag': '"' + hashlib.md5(data).hexdigest() + '"'}
    def download_fileobj(self, bucket, key, output):
        if key not in self.objects:
            self._error('NoSuchKey')
        output.write(self.objects[key])

class R2PublishRecovery(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.apk = Path(temp.name) / 'app.apk'
        self.apk.write_bytes(b'Test-only pretend APK; apksigner and aapt are mocked.')
        self.r2 = FakeR2()
        env = {'ERP_RELEASE_R2_ACCOUNT_ID': 'a' * 32,
               'ERP_RELEASE_R2_BUCKET': 'erp-android-releases',
               'ERP_ANDROID_CERT_SHA256': 'c' * 64,
               'ERP_RELEASE_R2_WRITE_ACCESS_KEY_ID': 'not-a-real-key',
               'ERP_RELEASE_R2_WRITE_SECRET_ACCESS_KEY': 'not-a-real-secret',
               'ERP_R2_BUCKET': 'erp-r1-media'}
        patch = mock.patch.dict(os.environ, env)
        patch.start(); self.addCleanup(patch.stop)
        client = mock.patch('boto3.client', return_value=self.r2)
        client.start(); self.addCleanup(client.stop)
        verify = mock.patch.object(publisher, 'verify', side_effect=self.fake_verify)
        verify.start(); self.addCleanup(verify.stop)
        self.arg = SimpleNamespace(apk=self.apk, tools=Path(temp.name), sha='f' * 40,
            code=1, version='1.0.0', notes='Cập nhật ERP',
            approval='https://github.com/khuongbinhinfo-a11y/erp/issues/46',
            uat='https://github.com/khuongbinhinfo-a11y/erp/issues/46#issuecomment-uat')
    def fake_verify(self, path, *_args):
        self.assertEqual(Path(path).read_bytes(), self.apk.read_bytes())
    def run_publish(self):
        with mock.patch('builtins.print'):
            publisher.publish(self.arg)
    def assert_complete(self):
        current = json.loads(self.r2.objects['releases/latest.json'])
        history = json.loads(self.r2.objects[f'releases/{self.arg.code}/manifest.json'])
        self.assertEqual(current['sourceSha'], self.arg.sha)
        self.assertEqual(current['sha256'], publisher.digest(self.apk))
        self.assertEqual(history['versionCode'], self.arg.code)
        self.assertEqual(self.r2.objects[f'releases/{self.arg.code}/erp-{self.arg.code}.apk'], self.apk.read_bytes())
        return current
    def test_first_publish_and_exact_retry(self):
        self.run_publish()
        original = self.assert_complete()
        self.run_publish()
        self.assertEqual(original, self.assert_complete())
    def test_timeout_after_apk_commit(self):
        self.r2.inject['releases/1/erp-1.apk'] = 'after'
        self.run_publish(); self.assert_complete()
    def test_timeout_after_immutable_manifest_commit(self):
        self.r2.inject['releases/1/manifest.json'] = 'after'
        self.run_publish(); self.assert_complete()
    def test_timeout_after_latest_pointer_commit(self):
        self.r2.inject['releases/latest.json'] = 'after'
        self.run_publish(); self.assert_complete()
    def test_retry_after_only_apk_committed(self):
        self.r2.objects['releases/1/erp-1.apk'] = self.apk.read_bytes()
        self.run_publish(); self.assert_complete()
    def test_conflicting_bytes_must_not_move_latest(self):
        self.run_publish()
        before = self.assert_complete()
        self.apk.write_bytes(b'Different bytes at the same version')
        with self.assertRaises(ValueError):
            self.run_publish()
        self.assertEqual(json.loads(self.r2.objects['releases/latest.json']), before)
    def test_incremental_version_and_no_downgrade(self):
        self.run_publish()
        old = self.assert_complete()
        self.arg.code = 2; self.arg.version = '1.0.1'
        self.run_publish()
        self.assertEqual(self.assert_complete()['versionCode'], 2)
        self.assertEqual(json.loads(self.r2.objects['releases/2/manifest.json'])['previous'], old)
        self.arg.code = 1; self.arg.version = '1.0.0'
        with self.assertRaises(ValueError):
            self.run_publish()
    def test_long_vietnamese_notes_never_block_history_readback(self):
        self.arg.notes = 'ấ' * 3000
        self.run_publish()
        previous = self.assert_complete()
        self.arg.code = 2; self.arg.version = '1.0.1'
        self.run_publish()
        self.assertEqual(json.loads(self.r2.objects['releases/2/manifest.json'])['previous'], previous)
        self.assertEqual(self.assert_complete()['versionCode'], 2)
    def test_reject_latest_manifest_over_native_api_16k_limit(self):
        self.arg.notes = '😀' * 4000
        with self.assertRaises(ValueError):
            self.run_publish()
        self.assertNotIn('releases/latest.json', self.r2.objects)
    def test_immutable_manifest_mismatch_denied(self):
        self.run_publish()
        original = self.assert_complete()
        self.arg.sha = 'e' * 40
        with self.assertRaises(ValueError):
            self.run_publish()
        self.assertEqual(json.loads(self.r2.objects['releases/latest.json']), original)

if __name__ == '__main__':
    unittest.main()
