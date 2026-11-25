// Restricted one-version ERP APK UAT uploader via GitHub Actions OIDC.
// No secret, token, public APK or latest.json is stored in this Worker.
const ISSUER = "https://token.actions.githubusercontent.com";
const JWKS = ISSUER + "/.well-known/jwks";
const AUDIENCE = "erp-android-r2-stage-0.1.0";
const REPO = "khuongbinhinfo-a11y/erp";
const REPO_ID = "1466503632";
const ENVIRONMENT = "android-r2-publish";
const WORKFLOW_REF = REPO + "/.github/workflows/erp-android-r2-oidc-stage.yml@refs/heads/main";
const SOURCE_SHA = "e1bf3eeb956b69d70ed678f3b827030be573a72c";
const SIGNER = "545d17fc51c8d24de4d73cb84ff7c3953f79c7d14efc7ada29b7075110d0c028";
const APK_SHA = "385766285dfc21e4c9d8cca3ab9d332e94476df1ec5ddbe02628bc0dc46b1328";
const SIZE = 63425634;
const KEY = "releases/1/erp-1.apk";

function fail(status, message) {
  return new Response(message, {status, headers: {"cache-control":"no-store", "content-type":"text/plain; charset=utf-8"}});
}

function bytes(segment) {
  if (!/^[a-zA-Z0-9_-]+$/.test(segment)) throw Error("Invalid base64url");
  const padded = segment.replace(/-/g, "+").replace(/_/g, "/");
  const binary = atob(padded + "=".repeat((4 - padded.length % 4) % 4));
  return Uint8Array.from(binary, ch => ch.charCodeAt(0));
}

async function githubClaims(value) {
  if (typeof value !== "string" || value.length > 16000) throw Error("Invalid token length");
  const fields = value.split(".");
  if (fields.length !== 3) throw Error("Malformed JWT");
  const header = JSON.parse(new TextDecoder().decode(bytes(fields[0])));
  const payload = JSON.parse(new TextDecoder().decode(bytes(fields[1])));
  if (header.alg !== "RS256" || typeof header.kid !== "string") throw Error("Unsupported JWT algorithm");
  const now = Math.floor(Date.now() / 1000);
  if (payload.iss !== ISSUER || payload.aud !== AUDIENCE ||
      !Number.isFinite(payload.exp) || payload.exp < now ||
      !Number.isFinite(payload.iat) || payload.iat > now + 30 ||
      (payload.nbf !== undefined && payload.nbf > now + 30)) throw Error("JWT issuer, audience or time invalid");
  if (payload.repository !== REPO ||
      String(payload.repository_id) !== REPO_ID ||
      payload.environment !== ENVIRONMENT ||
      payload.sub !== "repo:" + REPO + ":environment:" + ENVIRONMENT ||
      payload.workflow_ref !== WORKFLOW_REF ||
      payload.ref !== "refs/heads/main" ||
      payload.event_name !== "workflow_run") throw Error("Unapproved GitHub workflow identity");

  const response = await fetch(JWKS, {headers: {"accept": "application/json"}});
  if (!response.ok) throw Error("GitHub public keys unavailable");
  const document = await response.json();
  const jwk = document.keys?.find(x => x.kid === header.kid && x.kty === "RSA" && x.use === "sig");
  if (!jwk?.n || !jwk?.e) throw Error("GitHub signing key unavailable");
  const key = await crypto.subtle.importKey("jwk",
    {kty:"RSA",n:jwk.n,e:jwk.e,ext:true},
    {name:"RSASSA-PKCS1-v1_5",hash:"SHA-256"},false,["verify"]);
  const signed = new TextEncoder().encode(fields[0] + "." + fields[1]);
  if (!await crypto.subtle.verify("RSASSA-PKCS1-v1_5",key,bytes(fields[2]),signed))
    throw Error("GitHub JWT signature rejected");
  return payload;
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (!(request.method === "PUT" && url.pathname === "/uat/0.1.0/upload") &&
        !(request.method === "GET" && url.pathname === "/uat/0.1.0/readback"))
      return fail(404, "Not found");
    const auth = request.headers.get("authorization") || "";
    if (!auth.startsWith("Bearer ")) return fail(401,"OIDC token required");
    try { await githubClaims(auth.slice(7)); }
    catch { return fail(403,"GitHub OIDC verification failed"); }
    if (!env.ERP_ANDROID_RELEASES) return fail(503,"R2 binding missing");

    if (request.method === "GET") {
      const object = await env.ERP_ANDROID_RELEASES.get(KEY);
      if (!object) return fail(404, "APK not staged");
      if (object.size !== SIZE || object.customMetadata?.sha256 !== APK_SHA)
        return fail(409, "Unverified immutable object");
      return new Response(object.body, {status:200,headers:{
        "content-type":"application/vnd.android.package-archive",
        "content-length":String(SIZE),"cache-control":"no-store",
        "x-erp-sha256":APK_SHA
      }});
    }

    if (request.headers.get("content-length") !== String(SIZE) ||
        request.headers.get("x-erp-sha256") !== APK_SHA ||
        request.headers.get("content-type") !== "application/vnd.android.package-archive" ||
        !request.body) return fail(400,"APK byte-length or hash declaration mismatch");
    const existing = await env.ERP_ANDROID_RELEASES.head(KEY);
    if (existing) {
      if (existing.size !== SIZE || existing.customMetadata?.sha256 !== APK_SHA)
        return fail(409,"Different object occupies immutable release key");
      return fail(200,"Immutable object already staged; verify GET bytes");
    }
    const written = await env.ERP_ANDROID_RELEASES.put(KEY,request.body,{
      onlyIf:{etagDoesNotMatch:"*"},
      httpMetadata:{contentType:"application/vnd.android.package-archive"},
      customMetadata:{sha256:APK_SHA,signersha256:SIGNER,sourcesha:SOURCE_SHA}
    });
    if (!written) {
      const found = await env.ERP_ANDROID_RELEASES.head(KEY);
      if (!found || found.size !== SIZE || found.customMetadata?.sha256 !== APK_SHA)
        return fail(409,"Concurrent immutable upload rejected");
    }
    return fail(201,"ERP_ANDROID_R2_IMMUTABLE_OBJECT_STAGED");
  }
};
