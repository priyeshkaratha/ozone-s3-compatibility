import ast
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from patch_s3_tests_for_ozone import patch_repo


# Trimmed excerpt of the real s3tests/functional/__init__.py: the pieces
# patch_repo() locates and rewrites, in the shape upstream ships them.
UPSTREAM_INIT = '''import pytest
from botocore.exceptions import ClientError

def list_versions(client, bucket, batch_size):
    kwargs = {'Bucket': bucket, 'MaxKeys': batch_size}
    truncated = True
    while truncated:
        listing = client.list_object_versions(**kwargs)

        kwargs['KeyMarker'] = listing.get('NextKeyMarker')
        kwargs['VersionIdMarker'] = listing.get('NextVersionIdMarker')
        truncated = listing['IsTruncated']

        objs = listing.get('Versions', []) + listing.get('DeleteMarkers', [])
        if len(objs):
            yield [{'Key': o['Key'], 'VersionId': o['VersionId']} for o in objs]

def nuke_bucket(client, bucket):
    batch_size = 128
    max_retain_date = None

    for objects in list_versions(client, bucket, batch_size):
        client.delete_objects(Bucket=bucket,
                Delete={'Objects': objects, 'Quiet': True},
                BypassGovernanceRetention=True)

    client.delete_bucket(Bucket=bucket)

def nuke_prefixed_buckets(prefix, client=None):
    pass

def get_unauthenticated_client():
    client = boto3.client('s3')
    return client

def configured_storage_classes():
    pass
'''


class S3TestsPatchTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name)
        self.target = self.repo / "s3tests" / "functional" / "__init__.py"
        self.target.parent.mkdir(parents=True)
        self.target.write_text(UPSTREAM_INIT)

    def test_list_versions_no_longer_calls_the_rejected_api(self):
        patch_repo(self.repo)
        patched = self.target.read_text()
        self.assertNotIn("client.list_object_versions", patched)
        ast.parse(patched)  # stays syntactically valid

    def test_nuke_bucket_cleanup_still_wired_to_patched_list_versions(self):
        patch_repo(self.repo)
        patched = self.target.read_text()
        self.assertIn("def list_versions(client, bucket, batch_size):\n    yield from ()", patched)
        self.assertIn("list_versions(client, bucket, batch_size)", patched.split("def nuke_bucket", 1)[1])

    def test_patching_is_idempotent(self):
        patch_repo(self.repo)
        once = self.target.read_text()
        patch_repo(self.repo)
        self.assertEqual(once, self.target.read_text())


if __name__ == "__main__":
    unittest.main()
