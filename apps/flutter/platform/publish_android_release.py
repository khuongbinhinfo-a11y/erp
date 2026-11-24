#!/usr/bin/env python3
"""Owner-approved immutable ERP APK publisher. No debug or foreign signer accepted."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

PACKAGE = "vn.erpdistribution.erp_distribution"
LATEST = "releases/latest.json"

def digest(path):
    with path.open("rb") as f:
        return hashlib.file_digest(f, "sha256").hexdigest()

def verify(path, code, version, signer, tools):
    if not 0 < path.stat().st_size <= 300 * 1024 * 1024:
        raise ValueError("Invalid APK size")
    certificates = subprocess.check_output([str(tools / "apksigner"), "verify", "--verbose",
                                             "--print-certs", str(path)], text=True)
    values = re.findall(r"Signer #[0-9]+ certificate SHA-256 digest: ([a-fA-F0-9]+)", certificates)
    if len(values) != 1 or values[0].lower() != signer:
        raise ValueError("Unexpected APK signer")
    badging = subprocess.check_output([str(tools / "aapt"), "dump", "badging", str(path)], text=True)
    match = re.search(r"^package: name='([^']+)' versionCode='([^']+)' versionName='([^']+)'", badging, re.M)
    if not match or match.groups() != (PACKAGE, str(code), version):
        raise ValueError("Unexpected APK package or version")

def read_manifest(s3, bucket, key):
    from botocore.exceptions import ClientError
    try:
        result = s3.get_object(Bucket=bucket, Key=key)
    except ClientError as e:
        if e.response["Error"]["Code"] in ("NoSuchKey","404","NotFound"):
            return None, None
        raise
    with result["Body"] as body:
        raw = body.read(16385)
    if len(raw) > 16384:
        raise ValueError("Invalid manifest")
    return json.loads(raw), result["ETag"]

def confirm_remote_apk(s3, bucket, key, args, expected_sha, expected_size, signer):
    """An upload timeout is not failure unless the read-back is missing/mismatched."""
    with tempfile.TemporaryDirectory() as folder:
        downloaded = Path(folder) / "readback.apk"
        with downloaded.open("wb") as f:
            s3.download_fileobj(bucket, key, f)
        if downloaded.stat().st_size != expected_size or digest(downloaded) != expected_sha:
            raise ValueError("R2 readback mismatch: immutable APK conflict")
        verify(downloaded, args.code, args.version, signer, args.tools)


def publish(args):
    import boto3
    account = os.environ["ERP_RELEASE_R2_ACCOUNT_ID"]
    bucket = os.environ["ERP_RELEASE_R2_BUCKET"]
    signer = os.environ["ERP_ANDROID_CERT_SHA256"].lower()
    if not re.fullmatch("[a-f0-9]{32}", account) or not re.fullmatch("[a-z0-9][a-z0-9-]{1,62}[a-z0-9]", bucket):
        raise ValueError("Invalid release target")
    if bucket == os.environ.get("ERP_R2_BUCKET") or not bucket.startswith("erp-android-"):
        raise ValueError("Release bucket must be independent and ERP Android only")
    if not re.fullmatch("[a-f0-9]{64}", signer) or not re.fullmatch("[a-f0-9]{40}", args.sha):
        raise ValueError("Invalid signing or source identity")
    if not 1 <= args.code <= 999999999 or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", args.version):
        raise ValueError("Invalid version")
    if not args.approval or not args.uat or len(args.notes) > 4000:
        raise ValueError("Explicit owner release approval and UAT evidence required")
    verify(args.apk, args.code, args.version, signer, args.tools)
    sha, size = digest(args.apk), args.apk.stat().st_size
    s3 = boto3.client("s3", endpoint_url=f"https://{account}.r2.cloudflarestorage.com",
        region_name="auto", aws_access_key_id=os.environ["ERP_RELEASE_R2_WRITE_ACCESS_KEY_ID"],
        aws_secret_access_key=os.environ["ERP_RELEASE_R2_WRITE_SECRET_ACCESS_KEY"])
    old, etag = read_manifest(s3, bucket, LATEST)
    if old is not None:
        if old.get("packageName") != PACKAGE or old.get("signerSha256") != signer:
            raise ValueError("Current release has unexpected identity")
        if args.code < old["versionCode"]:
            raise ValueError("Version must not decrease")

    key = f"releases/{args.code}/erp-{args.code}.apk"
    history_key = f"releases/{args.code}/manifest.json"
    existing_history, _ = read_manifest(s3, bucket, history_key)
    if existing_history is not None:
        timestamp = existing_history.get("releasedAt")
        if not isinstance(timestamp, str):
            raise ValueError("Invalid existing immutable manifest")
    else:
        timestamp = datetime.datetime.now(datetime.timezone.utc).isoformat()
    manifest = dict(schema=1, versionCode=args.code, versionName=args.version, packageName=PACKAGE,
        signerSha256=signer, sha256=sha, size=size, objectKey=key, sourceSha=args.sha,
        notes=args.notes, releasedAt=timestamp)
    if old is not None and old["versionCode"] == args.code and old != manifest:
        raise ValueError("A different version is already active at this versionCode")
    previous = existing_history.get("previous") if (old == manifest and existing_history) else old
    history = dict(manifest, approval=args.approval, uat=args.uat, previous=previous)
    if existing_history is not None and existing_history != history:
        raise ValueError("Immutable version manifest conflicts with this release")
    if old == manifest and existing_history is None:
        raise ValueError("Active release is missing its immutable version manifest")

    # Treat timeout-after-COMMIT and an existing matching APK identically. Never overwrite.
    try:
        with args.apk.open("rb") as f:
            s3.put_object(Bucket=bucket, Key=key, Body=f, ContentLength=size,
                ContentType="application/vnd.android.package-archive", IfNoneMatch="*",
                Metadata={"sha256":sha,"signersha256":signer})
    except Exception as upload_error:
        try:
            confirm_remote_apk(s3, bucket, key, args, sha, size, signer)
        except Exception:
            raise upload_error
    else:
        confirm_remote_apk(s3, bucket, key, args, sha, size, signer)

    if existing_history is None:
        payload = json.dumps(history, ensure_ascii=False, separators=(",", ":")).encode()
        try:
            s3.put_object(Bucket=bucket, Key=history_key, Body=payload,
                ContentType="application/json", IfNoneMatch="*")
        except Exception as manifest_error:
            recovered, _ = read_manifest(s3, bucket, history_key)
            if recovered != history:
                raise manifest_error
    immutable, _ = read_manifest(s3, bucket, history_key)
    if immutable != history:
        raise ValueError("Immutable version manifest readback mismatch")

    if old != manifest:
        latest = json.dumps(manifest, ensure_ascii=False, separators=(",", ":")).encode()
        condition = {"IfMatch":etag} if etag else {"IfNoneMatch":"*"}
        try:
            s3.put_object(Bucket=bucket, Key=LATEST, Body=latest,
                ContentType="application/json", CacheControl="no-store", **condition)
        except Exception as commit_error:
            recovered, _ = read_manifest(s3, bucket, LATEST)
            if recovered != manifest:
                raise commit_error
    current, _ = read_manifest(s3, bucket, LATEST)
    if current != manifest:
        raise ValueError("Latest pointer readback mismatch")
    print(json.dumps({"versionCode":args.code,"sha256":sha,"size":size,"sourceSha":args.sha,
        "signerSha256":signer,"readback":"verified","objectKey":key}))


if __name__=="__main__":
    p=argparse.ArgumentParser()
    p.add_argument("--apk",type=Path,required=True)
    p.add_argument("--tools",type=Path,required=True)
    p.add_argument("--sha",required=True)
    p.add_argument("--code",type=int,required=True)
    p.add_argument("--version",required=True)
    p.add_argument("--notes",required=True)
    p.add_argument("--approval",required=True)
    p.add_argument("--uat",required=True)
    publish(p.parse_args())
