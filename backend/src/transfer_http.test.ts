import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { resolve } from "node:path";
import type { AddressInfo } from "node:net";
import { Pool } from "pg";
import { hashPassword } from "./auth.ts";
import { applyMigrations } from "./migrate.ts";
import { bootstrapInstallation } from "./bootstrap.ts";
import { buildApp } from "./server.ts";
import { isDatabaseReady } from "./db.ts";

const source=process.env.DATABASE_URL;
const ci=(()=>{
 try{const u=new URL(source??"");return ["localhost","127.0.0.1"].includes(u.hostname)
   &&u.pathname==="/erp_ci"&&u.username==="erp_ci";}
 catch{return false;}
})();
test("R3.3 transfer PostgreSQL: physical dispatch, in-transit, partial and raced receipt",
 {skip:!ci},async()=>{
 const admin=new Pool({connectionString:source,max:2});
 const name="erp_ci_transfer_"+randomUUID().replaceAll("-","").slice(0,12);
 let db:Pool|null=null,server:ReturnType<typeof buildApp>|null=null;
 try{
  await admin.query('CREATE DATABASE "'+name+'"');
  const uri=new URL(source!);uri.pathname="/"+name;
  db=new Pool({connectionString:uri.toString(),max:8,query_timeout:12000});
  db.on("error",()=>{});
  assert.equal((await applyMigrations(db,resolve(process.cwd(),"db/migrations"))).applied.length,19);
  assert.equal((await applyMigrations(db,resolve(process.cwd(),"db/migrations"))).skipped.length,19);
  const password="Synthetic-transfer-"+randomUUID();
  const root=await bootstrapInstallation(db,{code:"transfer-r3",displayName:"Transfer synthetic",
    adminLogin:"owner",adminPassword:password});
  const t=root.installationId,b=root.branchId,w=root.warehouseId;
  const dest=(await db.query<{id:string}>(
   "INSERT INTO warehouse(installation_id,branch_id,code,name) VALUES($1,$2,'DEST','Kho nhận') RETURNING id",
   [t,b])).rows[0]!.id;
  server=buildApp(()=>isDatabaseReady(db!),async()=>true,{
   pool:db,installationId:t,allowedOrigin:"https://erp.example.test",
   throttleSecret:"synthetic-"+randomUUID(),
  });
  await new Promise<void>(ok=>server!.listen(0,"127.0.0.1",ok));
  const host="http://127.0.0.1:"+(server.address() as AddressInfo).port;
  const call=async(path:string,method="GET",data?:unknown,token?:string,
    headers:Record<string,string>={})=>{
   const r=await fetch(host+path,{method,headers:{
    origin:"https://erp.example.test",
    ...(data===undefined?{}:{"content-type":"application/json"}),
    ...(token?{authorization:"Bearer "+token}:{}),...headers},
    body:data===undefined?undefined:JSON.stringify(data)});
   return {status:r.status,body:r.status===204?{}:await r.json() as Record<string,any>};
  };
  const login=await call("/v1/auth/login","POST",{loginName:"owner",password});
  assert.equal(login.status,200,JSON.stringify(login.body));
  const token=login.body.token as string;
  const make=(path:string,data:unknown,revision=0,key="tx-"+randomUUID())=>
    call(path,"POST",data,token,{"idempotency-key":key,"if-match":String(revision)});
  const product=await make("/v1/catalog/products",{
    branchId:b,code:"TX1",name:"Transfer test SKU",baseUnit:"cai"});
  assert.equal(product.status,201,JSON.stringify(product.body));
  const p=product.body.id as string;
  const opening=await make("/v1/inventory/openings",{
    branchId:b,warehouseId:w,productId:p,quantity:"5"});
  assert.equal(opening.status,201,JSON.stringify(opening.body));
  const scope={branchId:b,sourceWarehouseId:w,destinationWarehouseId:dest};
  const line={productId:p,quantity:"3"};
  const endpoint="/v1/inventory/transfers";
  const draft={...scope,note:"Transit audit",lines:[line]};
  assert.equal((await make(endpoint,draft)).status,403);
  await db.query(
   `INSERT INTO user_role_warehouse(installation_id,user_id,role_id,branch_id,warehouse_id)
   SELECT ur.installation_id,ur.user_id,ur.role_id,ur.branch_id,$4
   FROM user_role ur JOIN app_role r ON r.installation_id=ur.installation_id
     AND r.id=ur.role_id
   WHERE ur.installation_id=$1 AND ur.user_id=$2 AND ur.branch_id=$3
      AND r.code='PRIMARY_OWNER_MAIN' ON CONFLICT DO NOTHING`,
   [t,root.actorId,b,dest]);
  const k="create-"+randomUUID();
  const created=await make(endpoint,draft,0,k);
  assert.equal(created.status,201,JSON.stringify(created.body));
  const id=created.body.id as string;
  assert.deepEqual((await make(endpoint,draft,0,k)).body,created.body);
  assert.equal((await make(endpoint,{...draft,lines:[{...line,quantity:"4"}]},0,k)).status,409);
  const detailPath=endpoint+"/"+id+"?branchId="+b+
   "&sourceWarehouseId="+w+"&destinationWarehouseId="+dest+"&warehouseId="+w;
  const detail=await call(detailPath,"GET",undefined,token);
  assert.equal(detail.status,200,JSON.stringify(detail.body));
  assert.equal(detail.body.transfer.lines[0].dispatchedBase,"3.000000");
  assert.equal((await call(endpoint+"?branchId="+b+"&warehouseId="+w)).status,401);
  assert.equal((await call(endpoint+"?branchId="+b+"&warehouseId="+w,
   "GET",undefined,token,{origin:"https://evil.example.test"})).status,403);
  // Approval never stamps dispatch actor/time before the source ledger is posted.
  await assert.rejects(db.query(
    `UPDATE inventory_transfer SET status='APPROVED',revision=revision+1,
       approved_by=$4,approved_at=now(),dispatched_by=$4,dispatched_at=now()
     WHERE installation_id=$1 AND branch_id=$2 AND id=$3`,
     [t,b,id,root.actorId]),/lifecycle mutation invalid/i);
  const approve=await make(endpoint+"/"+id+"/approve",scope,0);
  assert.equal(approve.status,200,JSON.stringify(approve.body));
  assert.equal(approve.body.status,"APPROVED");
  // A matching physical issue must not commit until this transfer reaches IN_TRANSIT.
  const issueOnly=await db.connect();
  try{
   await issueOnly.query("BEGIN");
   await issueOnly.query(`INSERT INTO inventory_ledger(installation_id,branch_id,
     warehouse_id,product_id,kind,source_type,source_id,source_line,
     delta_base,actor_id,request_id)
     VALUES($1,$2,$3,$4,'TRANSFER_OUT','TRANSFER',$5,1,-3,$6,
       'issue-without-dispatch')`,[t,b,w,p,id,root.actorId]);
   await assert.rejects(issueOnly.query("COMMIT"),/requires dispatch transition at commit/i);
  }finally{await issueOnly.query("ROLLBACK").catch(()=>undefined);issueOnly.release();}
  // A direct database writer cannot create a fake already-dispatched header.
  await assert.rejects(db.query(
    `INSERT INTO inventory_transfer(installation_id,branch_id,
      source_warehouse_id,destination_warehouse_id,status,revision,
      created_by,approved_by,approved_at,dispatched_by,dispatched_at,request_id)
     VALUES($1,$2,$3,$4,'IN_TRANSIT',2,$5,$5,now(),$5,now(),
       'forged-transfer-fixture')`,
    [t,b,w,dest,root.actorId]),/must begin in CREATED/i);
  // A malformed zero-line document must never be dispatched by direct SQL.
  const empty=await db.query<{id:string}>(
   `INSERT INTO inventory_transfer(installation_id,branch_id,source_warehouse_id,
     destination_warehouse_id,created_by,request_id)
    VALUES($1,$2,$3,$4,$5,'empty-transfer-fixture') RETURNING id`,
   [t,b,w,dest,root.actorId]);
  await assert.rejects(db.query(`UPDATE inventory_transfer
    SET status='CANCELLED',revision=revision+1,approved_by=$4,approved_at=now()
    WHERE installation_id=$1 AND branch_id=$2 AND id=$3`,
    [t,b,empty.rows[0]!.id,root.actorId]),/lifecycle mutation invalid/i);
  await db.query(`UPDATE inventory_transfer SET status='APPROVED',
      revision=revision+1,approved_by=$4,approved_at=now()
    WHERE installation_id=$1 AND branch_id=$2 AND id=$3`,
    [t,b,empty.rows[0]!.id,root.actorId]);
  await assert.rejects(db.query(`UPDATE inventory_transfer SET status='IN_TRANSIT',
      revision=revision+1,dispatched_by=$4,dispatched_at=now()
    WHERE installation_id=$1 AND branch_id=$2 AND id=$3`,
    [t,b,empty.rows[0]!.id,root.actorId]),/requires at least one line/i);
  // Codex P2: direct status changes cannot skip the physical dispatch ledger.
  await assert.rejects(db.query(
   `UPDATE inventory_transfer SET status='IN_TRANSIT',
     revision=revision+1,dispatched_by=$4,dispatched_at=now()
     WHERE installation_id=$1 AND branch_id=$2 AND id=$3`,
   [t,b,id,root.actorId]),/requires one source issue per line/i);
  const before=await call("/v1/inventory/balances?branchId="+b+"&warehouseId="+w,
    "GET",undefined,token);
  assert.equal(before.body.items[0].onHand,"5.000000");
  const dispatchKey="dispatch-"+randomUUID();
  const sent=await make(endpoint+"/"+id+"/dispatch",scope,1,dispatchKey);
  assert.equal(sent.status,200,JSON.stringify(sent.body));
  assert.equal(sent.body.status,"IN_TRANSIT");
  assert.deepEqual((await make(endpoint+"/"+id+"/dispatch",scope,1,dispatchKey)).body,sent.body);
  // The database cannot mark a transfer as fully received without receipts.
  await assert.rejects(db.query(
   `UPDATE inventory_transfer SET status='RECEIVED',revision=revision+1
      WHERE installation_id=$1 AND branch_id=$2 AND id=$3`,
    [t,b,id]),/cannot receive without posted receipt lines/i);
  // Codex P1: a ledger credit with only a header and no accepted line must fail at COMMIT.
  const direct=await db.connect();
  try{
   await direct.query("BEGIN");
   const head=await direct.query<{id:string}>(
    `INSERT INTO inventory_transfer_receipt(installation_id,branch_id,transfer_id,
       destination_warehouse_id,posted_by,request_id)
      VALUES($1,$2,$3,$4,$5,'synthetic-orphan') RETURNING id`,
    [t,b,id,dest,root.actorId]);
   await direct.query(
    `INSERT INTO inventory_ledger(installation_id,branch_id,warehouse_id,product_id,
       kind,source_type,source_id,source_line,delta_base,actor_id,request_id)
     VALUES($1,$2,$3,$4,'TRANSFER_IN','TRANSFER',$5,1,0.5,$6,'synthetic-orphan')`,
    [t,b,dest,p,head.rows[0]!.id,root.actorId]);
   await assert.rejects(direct.query("COMMIT"),/no accepted receipt line/i);
  }finally{await direct.query("ROLLBACK").catch(()=>undefined);direct.release();}

  // Even a perfectly matched receipt fact must not commit without updating
  // the transfer status in the same transaction.
  const receiptOnly=await db.connect();
  try{
   await receiptOnly.query("BEGIN");
   const forgedReceipt=await receiptOnly.query<{id:string}>(
    `INSERT INTO inventory_transfer_receipt(installation_id,branch_id,
      transfer_id,destination_warehouse_id,posted_by,request_id)
     VALUES($1,$2,$3,$4,$5,'receipt-without-transition') RETURNING id`,
    [t,b,id,dest,root.actorId]);
   const movement=await receiptOnly.query<{id:string}>(
    `INSERT INTO inventory_ledger(installation_id,branch_id,warehouse_id,
      product_id,kind,source_type,source_id,source_line,delta_base,actor_id,request_id)
     VALUES($1,$2,$3,$4,'TRANSFER_IN','TRANSFER',$5,1,1,$6,
       'receipt-without-transition') RETURNING id`,
     [t,b,dest,p,forgedReceipt.rows[0]!.id,root.actorId]);
   await receiptOnly.query(`INSERT INTO inventory_transfer_receipt_line(
      installation_id,branch_id,receipt_id,line_no,transfer_id,transfer_line_no,
      product_id,destination_warehouse_id,quantity_base,ledger_id)
     VALUES($1,$2,$3,1,$4,1,$5,$6,1,$7)`,
    [t,b,forgedReceipt.rows[0]!.id,id,p,dest,movement.rows[0]!.id]);
   await assert.rejects(receiptOnly.query("COMMIT"),/requires receipt status transition at commit/i);
  }finally{await receiptOnly.query("ROLLBACK").catch(()=>undefined);receiptOnly.release();}
  const sourceStock=await call("/v1/inventory/balances?branchId="+b+"&warehouseId="+w,
    "GET",undefined,token);
  assert.equal(sourceStock.body.items[0].onHand,"2.000000");
  // Insufficient dispatch stock is a definitive, correctable 409, never 503.
  const tooMuch=await make(endpoint,{...draft,
    lines:[{productId:p,quantity:"9"}]},0);
  assert.equal(tooMuch.status,201);
  assert.equal((await make(endpoint+"/"+tooMuch.body.id+"/approve",scope,0)).status,200);
  const insufficient=await make(endpoint+"/"+tooMuch.body.id+"/dispatch",scope,1);
  assert.equal(insufficient.status,409,JSON.stringify(insufficient.body));
  const destinationBefore=await call("/v1/inventory/balances?branchId="+b+
    "&warehouseId="+dest,"GET",undefined,token);
  assert.equal(destinationBefore.body.items.length,0);
  const transit=await db.query<{in_transit_base:string}>(
    `SELECT in_transit_base::text FROM inventory_transfer_in_transit
     WHERE installation_id=$1 AND branch_id=$2 AND transfer_id=$3`,[t,b,id]);
  assert.equal(transit.rows[0]?.in_transit_base,"3.000000");
  assert.equal((await make(endpoint+"/"+id+"/cancel",scope,2)).status,409);
  const receivePath=endpoint+"/"+id+"/receipts";
  const firstPayload={...scope,lines:[{transferLineNo:1,quantity:"1"}]};
  const receiptKey="receipt-"+randomUUID();
  const first=await make(receivePath,firstPayload,2,receiptKey);
  assert.equal(first.status,201,JSON.stringify(first.body));
  assert.equal(first.body.transferStatus,"PARTIALLY_RECEIVED");
  assert.deepEqual((await make(receivePath,firstPayload,2,receiptKey)).body,first.body);
  const middle=await db.query<{in_transit_base:string}>(
    `SELECT in_transit_base::text FROM inventory_transfer_in_transit
     WHERE installation_id=$1 AND branch_id=$2 AND transfer_id=$3`,[t,b,id]);
  assert.equal(middle.rows[0]?.in_transit_base,"2.000000");
  const over=await make(receivePath,{...scope,
    lines:[{transferLineNo:1,quantity:"3"}]},3);
  assert.equal(over.status,409,JSON.stringify(over.body));
  const second={...scope,lines:[{transferLineNo:1,quantity:"2"}]};
  const raced=await Promise.all([make(receivePath,second,3),make(receivePath,second,3)]);
  assert.deepEqual(raced.map(x=>x.status).sort(),[201,409],JSON.stringify(raced));
  const completed=await call(endpoint+"/"+id+"?branchId="+b+
   "&sourceWarehouseId="+w+"&destinationWarehouseId="+dest+"&warehouseId="+dest,
   "GET",undefined,token);
  assert.equal(completed.body.transfer.status,"RECEIVED");
  assert.equal(completed.body.transfer.lines[0].receivedBase,"3.000000");
  assert.equal(completed.body.transfer.lines[0].inTransitBase,"0.000000");
  assert.equal(completed.body.transfer.receipts.length,2);
  const receivedStock=await call("/v1/inventory/balances?branchId="+b+
    "&warehouseId="+dest,"GET",undefined,token);
  assert.equal(receivedStock.body.items[0].onHand,"3.000000");
  const movements=await db.query<{kind:string;n:string}>(
    `SELECT kind,count(*)::text AS n FROM inventory_ledger WHERE
      installation_id=$1 AND branch_id=$2 AND kind IN ('TRANSFER_IN','TRANSFER_OUT')
     GROUP BY kind ORDER BY kind`,[t,b]);
  assert.deepEqual(movements.rows,[{kind:"TRANSFER_IN",n:"2"},
    {kind:"TRANSFER_OUT",n:"1"}]);
  await assert.rejects(db.query(
   "UPDATE inventory_transfer_receipt_line SET quantity_base=9 WHERE installation_id=$1",[t]),
   /immutable/i);
  assert.equal((await make(receivePath,second,4)).status,409);
  // Transfer-only warehouse staff must access authorized selectors without catalog.read.
  const limitedPass="Synthetic-transfer-receiver-"+randomUUID();
  const limited=(await db.query<{id:string}>(
   `INSERT INTO app_user(installation_id,login_name,password_hash)
      VALUES($1,'receiver',$2) RETURNING id`,[t,await hashPassword(limitedPass)])).rows[0]!.id;
  const role=(await db.query<{id:string}>(
   `INSERT INTO app_role(installation_id,code)
     VALUES($1,'TRANSFER_RECEIVER_ONLY') RETURNING id`,[t])).rows[0]!.id;
  await db.query(`INSERT INTO user_role(installation_id,user_id,role_id,branch_id)
    VALUES($1,$2,$3,$4)`,[t,limited,role,b]);
  await db.query(`INSERT INTO user_role_warehouse(
    installation_id,user_id,role_id,branch_id,warehouse_id)
    VALUES($1,$2,$3,$4,$5)`,[t,limited,role,b,dest]);
  await db.query(`INSERT INTO role_permission(installation_id,role_id,permission_code)
    VALUES($1,$2,'inventory.transfer.read'),
          ($1,$2,'inventory.transfer.receive')`,[t,role]);
  const relog=await call("/v1/auth/login","POST",
    {loginName:"receiver",password:limitedPass});
  assert.equal(relog.status,200,JSON.stringify(relog.body));
  const receiverToken=relog.body.token as string;
  const transferScopes=await call(endpoint+"/scopes?branchId="+b,
    "GET",undefined,receiverToken);
  assert.equal(transferScopes.status,200,JSON.stringify(transferScopes.body));
  assert.equal(transferScopes.body.branches.length,1);
  assert.deepEqual(transferScopes.body.warehouses.map(
    (x:Record<string,string>)=>x.id),[dest]);
  assert.equal((await call("/v1/catalog/warehouses?branchId="+b,
    "GET",undefined,receiverToken)).status,403);
  assert.equal((await call(endpoint+"?branchId="+b+"&warehouseId="+dest,
    "GET",undefined,receiverToken)).status,200);
  assert.equal((await call(endpoint+"?branchId="+b+"&warehouseId="+w,
    "GET",undefined,receiverToken)).status,403);
  // Creator-only warehouse assignment must appear in selectors even without read.
  const creatorPass="Synthetic-transfer-creator-"+randomUUID();
  const creator=(await db.query<{id:string}>(
   `INSERT INTO app_user(installation_id,login_name,password_hash)
     VALUES($1,'creator',$2) RETURNING id`,[t,await hashPassword(creatorPass)])).rows[0]!.id;
  const creatorRole=(await db.query<{id:string}>(
   `INSERT INTO app_role(installation_id,code)
     VALUES($1,'TRANSFER_CREATOR_ONLY') RETURNING id`,[t])).rows[0]!.id;
  await db.query(`INSERT INTO user_role(installation_id,user_id,role_id,branch_id)
    VALUES($1,$2,$3,$4)`,[t,creator,creatorRole,b]);
  await db.query(`INSERT INTO user_role_warehouse(
    installation_id,user_id,role_id,branch_id,warehouse_id)
    VALUES($1,$2,$3,$4,$5)`,[t,creator,creatorRole,b,w]);
  await db.query(`INSERT INTO role_permission(installation_id,role_id,permission_code)
    VALUES($1,$2,'inventory.transfer.create')`,[t,creatorRole]);
  const creatorLogin=await call("/v1/auth/login","POST",
    {loginName:"creator",password:creatorPass});
  assert.equal(creatorLogin.status,200,JSON.stringify(creatorLogin.body));
  const creatorScopes=await call(endpoint+"/scopes?branchId="+b,
    "GET",undefined,creatorLogin.body.token);
  assert.equal(creatorScopes.status,200,JSON.stringify(creatorScopes.body));
  assert.deepEqual(creatorScopes.body.branches.map((x:Record<string,string>)=>x.id),[b]);
  assert.deepEqual(creatorScopes.body.warehouses.map((x:Record<string,string>)=>x.id),[w]);
  // SKU lookup uses only source transfer-create grant (no catalog.read).
  const transferProducts=await call(endpoint+"/products?branchId="+b+
    "&warehouseId="+w,"GET",undefined,creatorLogin.body.token);
  assert.equal(transferProducts.status,200,JSON.stringify(transferProducts.body));
  assert.deepEqual(transferProducts.body.items.map(
    (x:Record<string,string>)=>x.id),[p]);
  assert.equal((await call(endpoint+"/products?branchId="+b+
    "&warehouseId="+dest,"GET",undefined,creatorLogin.body.token)).status,403);
  const unknownWh=randomUUID();
  assert.equal((await call(endpoint+"?branchId="+b+"&warehouseId="+unknownWh,
    "GET",undefined,token)).status,403);
 }finally{
  if(server)await new Promise<void>(ok=>server!.close(()=>ok()));
  if(db)await db.end();
  await admin.query('DROP DATABASE IF EXISTS "'+name+'" WITH (FORCE)');
  await admin.end();
 }
});
