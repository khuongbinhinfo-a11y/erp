#!/usr/bin/env python3
"""Generate Flutter 3.50 platform scaffolding from SDK template, then apply ERP-only overlay."""
from pathlib import Path
import argparse
import os
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
PACKAGE = "vn.erpdistribution.erp_distribution"
ANDROID = "{http://schemas.android.com/apk/res/android}"
ET.register_namespace("android", ANDROID[1:-1])

def prepare(target):
    destination = ROOT / target
    if destination.exists():
        raise SystemExit("Native scaffold already exists; use a clean checkout")
    with tempfile.TemporaryDirectory() as temporary:
        generated = Path(temporary) / "erp_distribution"
        sdk = shutil.which("flutter.bat" if os.name == "nt" else "flutter")
        if not sdk:
            raise SystemExit("Flutter SDK missing from PATH")
        subprocess.run([sdk, "create", "--platforms=" + target,
                        "--org", "vn.erpdistribution", "--project-name", "erp_distribution",
                        "--android-language", "kotlin", "--no-pub", str(generated)], check=True)
        shutil.copytree(generated / target, destination)
    if target != "android":
        return
    app = destination / "app"
    main = app / "src/main"
    source = main / "kotlin" / PACKAGE.replace(".", "/") / "MainActivity.kt"
    if not source.is_file():
        raise SystemExit("Unexpected Flutter Android package template")
    shutil.copyfile(ROOT / "platform/android/MainActivity.kt", source)
    # Neutral branded launch/normal window background in both OS themes.
    # The persisted Flutter preference is restored before the first frame;
    # a dark user preference must not flash the default white Android window.
    for style_file in (main / "res").glob("values*/styles.xml"):
        styles = ET.parse(style_file)
        for style in styles.getroot().findall("style"):
            if style.get("name") not in ("LaunchTheme", "NormalTheme"):
                continue
            item = next((x for x in style.findall("item") if x.get("name") == "android:windowBackground"), None)
            if item is None:
                item = ET.SubElement(style, "item", {"name":"android:windowBackground"})
            item.text = "#102E24"
            for item in style.findall("item"):
                if item.get("name") == "android:windowSplashScreenBackground":
                    item.text = "#102E24"
        styles.write(style_file, encoding="utf-8", xml_declaration=True)
    xml_dir = main / "res/xml"
    xml_dir.mkdir(exist_ok=True)
    shutil.copyfile(ROOT / "platform/android/update_paths.xml", xml_dir / "erp_update_paths.xml")
    manifest = main / "AndroidManifest.xml"
    doc = ET.parse(manifest)
    root = doc.getroot()
    for permission in ["android.permission.INTERNET", "android.permission.REQUEST_INSTALL_PACKAGES"]:
        if not any(x.get(ANDROID+"name") == permission for x in root.findall("uses-permission")):
            root.insert(0, ET.Element("uses-permission", {ANDROID+"name":permission}))
    application = root.find("application")
    if application is None:
        raise SystemExit("Missing Android application")
    application.set(ANDROID+"label","ERP phân phối")
    application.set(ANDROID+"usesCleartextTraffic","false")
    # Preserve app-private files across updates, but don't export sessions through Android cloud backup.
    application.set(ANDROID+"allowBackup","false")
    provider = ET.SubElement(application, "provider", {
        ANDROID+"name":"androidx.core.content.FileProvider",
        ANDROID+"authorities":PACKAGE+".updates",
        ANDROID+"exported":"false", ANDROID+"grantUriPermissions":"true"})
    ET.SubElement(provider, "meta-data", {ANDROID+"name":"android.support.FILE_PROVIDER_PATHS",
                                        ANDROID+"resource":"@xml/erp_update_paths"})
    doc.write(manifest, encoding="utf-8", xml_declaration=True)
    gradle = app / "build.gradle.kts"
    content = gradle.read_text()
    if 'applicationId = "'+PACKAGE+'"' not in content or 'namespace = "'+PACKAGE+'"' not in content:
        raise SystemExit("Unexpected package identity")
    original = 'signingConfig = signingConfigs.getByName("debug")'
    if content.count(original) != 1:
        raise SystemExit("Unexpected Flutter signing template")
    # Release must never fall back to debug certificate.
    content = content.replace("    buildTypes {", '''
    signingConfigs {
        create("erpRelease") {
            storeFile = System.getenv("ERP_ANDROID_KEYSTORE")?.let { file(it) }
            storePassword = System.getenv("ERP_ANDROID_STORE_PASSWORD")
            keyAlias = System.getenv("ERP_ANDROID_KEY_ALIAS")
            keyPassword = System.getenv("ERP_ANDROID_STORE_PASSWORD")
        }
    }
    buildTypes {''')
    content = content.replace(original, 'signingConfig = signingConfigs.getByName("erpRelease")')
    gradle.write_text(content + '\n\ndependencies { implementation("androidx.core:core:1.15.0") }\n')
    # A missing secret must abort rather than produce an unsigned release.
    with gradle.open("a") as handle:
        handle.write('''
tasks.configureEach {
    if (name == "validateSigningRelease") {
        doFirst {
            listOf("ERP_ANDROID_KEYSTORE", "ERP_ANDROID_STORE_PASSWORD",
                   "ERP_ANDROID_KEY_ALIAS").forEach {
                require(!System.getenv(it).isNullOrBlank()) { "Protected ERP Android signing is missing" }
            }
        }
    }
}
''')

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("target", choices=["android", "windows"])
    prepare(parser.parse_args().target)
