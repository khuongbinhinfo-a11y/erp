import {execFileSync} from "node:child_process";
import {readFileSync,rmSync} from "node:fs";
import {fileURLToPath} from "node:url";
import {resolve} from "node:path";
const root=fileURLToPath(new URL("../",import.meta.url));
const sha=execFileSync("git",["rev-parse","HEAD"],{cwd:root,encoding:"utf8"}).trim();
if(!/^[0-9a-f]{40}$/.test(sha))throw new Error("ERP_BUILD_SHA_INVALID");
if(execFileSync("git",["status","--porcelain","--untracked-files=no"],{cwd:root,encoding:"utf8"}).trim())
 throw new Error("ERP_BUILD_REQUIRES_CLEAN_TRACKED_TREE");
if(process.env.ERP_APPROVED_SHA&&process.env.ERP_APPROVED_SHA!==sha)
 throw new Error("ERP_BUILD_SHA_NOT_APPROVED");
const output=resolve(root,"dist/compute.mjs");
rmSync(output,{force:true});
execFileSync("bun",["build","deploy/entry.ts","--target=bun","--outfile",output,
 "--define","ERP_RELEASE_SHA="+JSON.stringify(sha)],{cwd:root,stdio:"inherit"});
const bundle=readFileSync(output,"utf8");
if(!bundle.includes(sha)||!bundle.includes("/health/release")||!bundle.includes("/v1/sales/entry-settings"))
 throw new Error("ERP_BUILD_CONTRACT_MISSING");
console.log("ERP_COMPUTE_BUILD_VERIFIED "+sha);
