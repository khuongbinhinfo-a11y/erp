// Public, read-only downloader for one owner-approved ERP Android UAT APK.
// The R2 bucket itself stays private; no listing, write, or other object access.
const OBJECT = "releases/1/erp-1.apk";
const ROUTE = "/ERP-Android-0.1.0.apk";
const SHA = "385766285dfc21e4c9d8cca3ab9d332e94476df1ec5ddbe02628bc0dc46b1328";
const SIGNER = "545d17fc51c8d24de4d73cb84ff7c3953f79c7d14efc7ada29b7075110d0c028";
const SIZE = 63425634;

function fail(status, message) {
  return new Response(message, {status,headers:{
    "content-type":"text/plain; charset=utf-8",
    "cache-control":"no-store",
    "x-content-type-options":"nosniff"
  }});
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if ((request.method !== "GET" && request.method !== "HEAD") ||
        url.pathname !== ROUTE || url.search)
      return fail(404,"Not found");
    if (!env.ERP_ANDROID_RELEASES)
      return fail(503,"Download unavailable");

    // A fixed key and independent checks prevent inadvertently serving a different release.
    const metadata = await env.ERP_ANDROID_RELEASES.head(OBJECT);
    if (!metadata) return fail(404,"APK unavailable");
    if (metadata.size !== SIZE ||
        metadata.customMetadata?.sha256 !== SHA ||
        metadata.customMetadata?.signersha256 !== SIGNER)
      return fail(409,"APK identity mismatch");

    const headers = new Headers({
      "content-type":"application/vnd.android.package-archive",
      "content-disposition":'attachment; filename="ERP-Android-0.1.0.apk"',
      "content-length":String(SIZE),
      "x-content-type-options":"nosniff",
      "cache-control":"public, max-age=3600, immutable",
      "x-erp-sha256":SHA,
      "x-erp-signer-sha256":SIGNER
    });

    if (request.method === "HEAD")
      return new Response(null,{status:200,headers});

    // Stream from R2, rather than buffering a 63 MB APK in Worker memory.
    const object = await env.ERP_ANDROID_RELEASES.get(OBJECT);
    if (!object || object.size !== SIZE ||
        object.customMetadata?.sha256 !== SHA ||
        object.customMetadata?.signersha256 !== SIGNER)
      return fail(409,"APK content mismatch");

    return new Response(object.body,{status:200,headers});
  }
};
