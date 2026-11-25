#!/usr/bin/env python3
"""Idempotently upload one verified, immutable ERP Android APK to private R2.

Does NOT activate releases/latest.json; device UAT is required before activation.
"""
import argparse
import hashlib
import os
from pathlib import Path
import re

ORIGINAL_SOURCE_SHA = "e1bf3eeb956b69d70ed678f3b827030be573a72c"
ORIGINAL_APK_SHA = "385766285dfc21e4c9d8cca3ab9d332e94476df1ec5ddbe02628bc0dc46b1328"
ORIGINAL_APK_BYTES = 63425634
ORIGINAL_SIGNER = "545d17fc51c8d24de4d73cb84ff7c3953f79c7d14efc7ada29b7075110d0c028"
OBJECT_KEY = "releases/1/erp-1.apk"


def digest(stream):
    hasher = hashlib.sha256()
    n = 0
    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
        hasher.update(chunk)
        n += len(chunk)
        if n > ORIGINAL_APK_BYTES:
            raise ValueError("R2 readback exceeds verified APK bytes")
    return hasher.hexdigest(), n


def remote_matches(s3, bucket):
    """Full remote content read-back, not an ETag or metadata-only check."""
    from botocore.exceptions import ClientError
    try:
        response = s3.get_object(Bucket=bucket, Key=OBJECT_KEY)
    except ClientError as e:
        if e.response.get("Error", {}).get("Code") in ("NoSuchKey", "404", "NotFound"):
            return False
        raise
    with response["Body"] as body:
        sha, size = digest(body)
    if sha != ORIGINAL_APK_SHA or size != ORIGINAL_APK_BYTES:
        raise ValueError("An object already exists at this immutable key but differs from the signed APK")
    return True


def stage(apk):
    import boto3

    account = os.environ["ERP_RELEASE_R2_ACCOUNT_ID"]
    bucket = os.environ["ERP_RELEASE_R2_BUCKET"]
    access_id = os.environ["ERP_RELEASE_R2_WRITE_ACCESS_KEY_ID"]
    access_secret = os.environ["ERP_RELEASE_R2_WRITE_SECRET_ACCESS_KEY"]
    expected_bucket = "erp-android-releases"
    if not re.fullmatch("[a-f0-9]{32}", account) or bucket != expected_bucket:
        raise ValueError("Invalid or non-isolated ERP Android R2 target")
    if not access_id or not access_secret:
        raise ValueError("Missing dedicated ERP Android R2 write credentials")
    if not apk.is_file() or apk.stat().st_size != ORIGINAL_APK_BYTES:
        raise ValueError("APK size does not match reviewed signing artifact")
    with apk.open("rb") as file:
        actual_sha, actual_size = digest(file)
    if actual_sha != ORIGINAL_APK_SHA or actual_size != ORIGINAL_APK_BYTES:
        raise ValueError("APK SHA-256 does not match reviewed signed artifact")

    s3 = boto3.client("s3", endpoint_url=f"https://{account}.r2.cloudflarestorage.com",
                      region_name="auto", aws_access_key_id=access_id,
                      aws_secret_access_key=access_secret)
    if remote_matches(s3, bucket):
        print(f"ERP_ANDROID_R2_STAGED_READBACK_PASS key={OBJECT_KEY} sha256={ORIGINAL_APK_SHA}")
        return
    try:
        with apk.open("rb") as file:
            s3.put_object(Bucket=bucket, Key=OBJECT_KEY, Body=file,
                          ContentLength=ORIGINAL_APK_BYTES,
                          ContentType="application/vnd.android.package-archive",
                          IfNoneMatch="*",
                          Metadata={"sha256": ORIGINAL_APK_SHA, "signersha256": ORIGINAL_SIGNER,
                                    "sourcesha": ORIGINAL_SOURCE_SHA})
    except Exception as e:
        # Timeout after server COMMIT must be resolved by a full read-before-retry.
        if not remote_matches(s3, bucket):
            raise e
    if not remote_matches(s3, bucket):
        raise ValueError("R2 immutable APK readback absent after upload")
    print(f"ERP_ANDROID_R2_STAGED_READBACK_PASS key={OBJECT_KEY} sha256={ORIGINAL_APK_SHA}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--apk", required=True, type=Path)
    stage(parser.parse_args().apk)
