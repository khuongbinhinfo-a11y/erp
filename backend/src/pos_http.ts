import {randomUUID} from "node:crypto";
import type {IncomingMessage,ServerResponse} from "node:http";
import type {PoolClient} from "pg";
import type {IdentityOptions} from "./identity_http.ts";
import {resolveSession} from "./auth.ts";
import {hasPermission} from "./rbac.ts";
import {executeMutation,readCommittedMutation,MutationFault,type MutationContext} from "./mutation.ts";
import {validIdempotencyKey} from "./contracts.ts";
import {parseOrder,create,confirm} from "./sales_http.ts";

const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const MONEY=/^(?:0|[1-9][0-9]{0,15})$/;
const QTY=/^(?:0|[1-9][0-9]{0,8})(?:\.[0-9]{1,3})?$/;
class PosFault extends Error {
 readonly status:number;
 readonly code:string;
 constructor(status:number,code:string){super(code);this.status=status;this.code=code;}
}
function id(v:unknown):string {
 if(typeof v!=="string"||!UUID.test(v))throw new PosFault(400,"INVALID_ID");
 return v;
}
function money(v:unknown):string{
 if(typeof v!=="string"||!MONEY.test(v))throw new PosFault(400,"INVALID_MONEY");
 return v;
}
function record(v:unknown):Record<string,unknown>{
 if(!v||typeof v!=="object"||Array.isArray(v))throw new PosFault(400,"INVALID_BODY");
 return v as Record<string,unknown>;
}
function only(v:Record<string,unknown>,keys:string[]){
 if(Object.keys(v).some(x=>!keys.includes(x)))throw new PosFault(400,"UNKNOWN_FIELD");
}
async function body(req:IncomingMessage){
 if(req.headers["content-type"]?.split(";")[0]?.trim()!=="application/json")
  throw new PosFault(415,"JSON_REQUIRED");
 let size=0;const chunks:Buffer[]=[];
 for await(const chunk of req){
  const bytes=Buffer.isBuffer(chunk)?chunk:Buffer.from(chunk as Uint8Array);
  size+=bytes.length;if(size>32768)throw new PosFault(413,"BODY_TOO_LARGE");
  chunks.push(bytes);
 }
 try{return record(JSON.parse(Buffer.concat(chunks).toString("utf8")) as unknown);}
 catch(e){if(e instanceof PosFault)throw e;throw new PosFault(400,"INVALID_JSON");}
}
function respond(res:ServerResponse,status:number,payload:unknown,requestId:string,cors?:string){
 res.writeHead(status,{"content-type":"application/json; charset=utf-8",
  "cache-control":"no-store","x-request-id":requestId,"x-content-type-options":"nosniff",
  "vary":"Origin",...(cors?{"access-control-allow-origin":cors,
  "access-control-allow-headers":"authorization,content-type,idempotency-key,if-match,x-request-id",
  "access-control-allow-methods":"GET,POST,OPTIONS"}:{})});
 res.end(status===204?"":JSON.stringify(payload));
}
function fail(res:ServerResponse,status:number,code:string,rid:string,cors?:string){
 const message:Record<string,string>={
  POS_MIGRATION_REQUIRED:"Chưa nâng cấp nghiệp vụ POS trên máy chủ.",
  FORBIDDEN:"Không đủ quyền bán lẻ tại chi nhánh và kho.",
  SHIFT_NOT_OPEN:"Ca bán đã đóng hoặc chưa được mở.",
  SHIFT_OWNER_MISMATCH:"Ca bán thuộc nhân viên khác.",
  INVALID_MONEY:"Số tiền phải là số nguyên VND không âm.",
  PAYMENT_INSUFFICIENT:"Số tiền khách đưa chưa đủ thanh toán.",
  BANK_OVERPAYMENT:"Số tiền chuyển khoản không được vượt tổng đơn.",
  PRICE_STALE:"Giá đã đổi. Hãy làm mới giỏ và xác nhận lại.",
  INSUFFICIENT_STOCK:"Kho không đủ hàng khả dụng. Hãy kiểm tra tồn.",
  RETURN_ALREADY_POSTED:"Đơn đã hoàn hàng. Không thể ghi nhận hai lần.",
  POS_RETURN_NOT_ALLOWED:"Không tìm thấy giao dịch hợp lệ để hoàn.",
 };
 respond(res,status,{error:{code,message:message[code]??"Không xử lý được giao dịch tại quầy.",requestId:rid}},rid,cors);
}
function mutation(req:IncomingMessage,requestId:string,t:string,actor:string,action:string,payload:unknown){
 const key=req.headers["idempotency-key"],revision=req.headers["if-match"];
 if(typeof key!=="string"||!validIdempotencyKey(key)||revision!=="0")
  throw new PosFault(400,"MUTATION_HEADERS_REQUIRED");
 return {installationId:t,actorId:actor,requestId,action,idempotencyKey:key,
  expectedRevision:0,payload} satisfies MutationContext;
}
async function perm(db:PoolClient,c:MutationContext,b:string,w:string,actions:string[]){
 for(const permission of actions)
  if(!await hasPermission(db,{installationId:c.installationId,actorId:c.actorId,
    permission,branchId:b,...(permission.startsWith("inventory.")?{warehouseId:w}:{})}))
   return false;
 return await hasPermission(db,{installationId:c.installationId,actorId:c.actorId,
  permission:"inventory.read",branchId:b,warehouseId:w});
}
async function requireShift(db:PoolClient,c:MutationContext,b:string,w:string,shiftId:string){
 const r=await db.query<{actor_id:string;warehouse_id:string;status:string}>(`
  SELECT actor_id,warehouse_id,status FROM retail_shift
  WHERE installation_id=$1 AND branch_id=$2 AND id=$3 FOR UPDATE`,
  [c.installationId,b,shiftId]);
 if(!r.rows[0]||r.rows[0].status!=="OPEN")throw new PosFault(409,"SHIFT_NOT_OPEN");
 if(r.rows[0].actor_id!==c.actorId||r.rows[0].warehouse_id!==w)
  throw new PosFault(403,"SHIFT_OWNER_MISMATCH");
}
async function warehouseLock(db:PoolClient,t:string,b:string,w:string){
 const row=await db.query(`SELECT id FROM warehouse WHERE installation_id=$1
   AND branch_id=$2 AND id=$3 FOR UPDATE`,[t,b,w]);
 if(!row.rowCount)throw new PosFault(404,"WAREHOUSE_NOT_FOUND");
}
function checkoutInput(raw:Record<string,unknown>){
 only(raw,["branchId","warehouseId","shiftId","customerId","priceListId","lines",
  "cashReceived","bankAmount"]);
 const branchId=id(raw.branchId),warehouseId=id(raw.warehouseId),
  shiftId=id(raw.shiftId),customerId=id(raw.customerId),priceListId=id(raw.priceListId);
 const cashReceived=money(raw.cashReceived),bankAmount=money(raw.bankAmount);
 if(!Array.isArray(raw.lines)||raw.lines.length===0||raw.lines.length>30)
  throw new PosFault(400,"INVALID_LINES");
 const seen=new Set<string>();
 const lines=raw.lines.map(x=>{
  const line=record(x);only(line,["sellSkuId","quantity","expectedPriceSignature"]);
  const sellSkuId=id(line.sellSkuId);
  if(seen.has(sellSkuId))throw new PosFault(400,"DUPLICATE_SKU");
  seen.add(sellSkuId);
  if(typeof line.quantity!=="string"||!QTY.test(line.quantity)||!/[1-9]/.test(line.quantity))
   throw new PosFault(400,"INVALID_QUANTITY");
  const expectedPriceSignature=line.expectedPriceSignature;
  if(typeof expectedPriceSignature!=="string"||!/^[0-9a-f]{64}$/.test(expectedPriceSignature))
   throw new PosFault(400,"PRICE_QUOTE_REQUIRED");
  return {sellSkuId,quantity:line.quantity,expectedPriceSignature};
 });
 return {branchId,warehouseId,shiftId,customerId,priceListId,cashReceived,bankAmount,lines};
}
type CheckoutInput=ReturnType<typeof checkoutInput>;
async function checkout(db:PoolClient,c:MutationContext,i:CheckoutInput){
 const t=c.installationId,b=i.branchId,w=i.warehouseId;
 // Warehouse-first lock is shared with inventory posting trigger. Cross-cashier
 // races serialize here before any price or stock facts are committed.
 await warehouseLock(db,t,b,w);
 await requireShift(db,c,b,w,i.shiftId);
 const walk=await db.query<{ok:boolean}>(`SELECT EXISTS(
  SELECT 1 FROM sales_walk_in_customer WHERE installation_id=$1 AND branch_id=$2
    AND customer_id=$3) AS ok`,[t,b,i.customerId]);
 const customerMode=walk.rows[0]?.ok?"WALK_IN" as const:"EXISTING" as const;
 const order=parseOrder({branchId:b,customerId:i.customerId,priceListId:i.priceListId,
  note:"Bán tại quầy",
  shipping:{warehouseId:w,deliveryChoice:"PICKUP",
   collectionPolicy:"COLLECT_ON_DELIVERY",customerMode},
  lines:i.lines});
 const checkoutId=randomUUID();
 const created=await create(db,c,order,checkoutId);
 const saleId=created.body.id;
 const confirmed=await confirm(db,c,saleId,b);
 const total=BigInt(created.body.total),cash=BigInt(i.cashReceived),bank=BigInt(i.bankAmount);
 if(bank>total)throw new PosFault(409,"BANK_OVERPAYMENT");
 const cashApplied=total-bank;
 if(cash<cashApplied)throw new PosFault(409,"PAYMENT_INSUFFICIENT");
 const change=cash-cashApplied;
 const fulfillmentId=randomUUID();
 await db.query(`INSERT INTO sales_fulfillment
  (installation_id,branch_id,id,order_id,version_no,warehouse_id,mode,actor_id,request_id)
  VALUES($1,$2,$3,$4,1,$5,'PICKUP',$6,$7)`,
  [t,b,fulfillmentId,saleId,w,c.actorId,c.requestId]);
 const lines=await db.query<{line_no:number;product_id:string;base_qty:string}>(`
  SELECT l.line_no,l.product_id,
    (l.quantity*s.conversion_to_base)::text AS base_qty
  FROM sales_order_line l
  JOIN catalog_sell_sku s ON s.installation_id=l.installation_id
   AND s.branch_id=l.branch_id AND s.id=l.sell_sku_id
  WHERE l.installation_id=$1 AND l.branch_id=$2 AND l.order_id=$3
   AND l.version_no=1 ORDER BY l.line_no`,[t,b,saleId]);
 if(lines.rows.length!==i.lines.length)throw new PosFault(409,"SKU_UNAVAILABLE");
 for(const line of lines.rows){
  // Never silently round down an exact conversion into a fabricated stock qty.
  const precise=await db.query<{ok:boolean}>(`
    SELECT ($1::numeric>0 AND $1::numeric=round($1::numeric,6)) AS ok`,[line.base_qty]);
  if(precise.rows[0]?.ok!==true)throw new PosFault(409,"STOCK_PRECISION_INVALID");
  await db.query(`INSERT INTO inventory_ledger
   (installation_id,branch_id,warehouse_id,product_id,kind,source_type,
    source_id,source_line,delta_base,actor_id,request_id)
   VALUES($1,$2,$3,$4,'ISSUE','FULFILLMENT',$5,$6,-$7::numeric,$8,$9)`,
   [t,b,w,line.product_id,fulfillmentId,line.line_no,line.base_qty,c.actorId,c.requestId]);
 }
 await db.query(`INSERT INTO retail_checkout
  (installation_id,branch_id,id,order_id,fulfillment_id,shift_id,
   warehouse_id,customer_id,grand_total,cash_received,bank_amount,change_due,
   cashier_id,request_id)
  VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9::numeric,$10::numeric,
   $11::numeric,$12::numeric,$13,$14)`,
  [t,b,checkoutId,saleId,fulfillmentId,i.shiftId,w,i.customerId,total.toString(),
   cash.toString(),bank.toString(),change.toString(),c.actorId,c.requestId]);
 if(total>0n){
  const debit=await db.query<{id:string}>(`
   INSERT INTO customer_receivable_ledger
    (installation_id,branch_id,customer_id,order_id,kind,source_id,amount,actor_id,request_id)
   VALUES($1,$2,$3,$4,'SALE',$5,$6::numeric,$7,$8) RETURNING id`,
    [t,b,i.customerId,saleId,checkoutId,total.toString(),c.actorId,c.requestId]);
  const saleLedgerId=debit.rows[0]!.id;
  for(const [method,amount] of [["CASH",cashApplied],["BANK_TRANSFER",bank]] as const){
   if(amount===0n)continue;
   const receipt=await db.query<{id:string}>(`
    INSERT INTO payment_receipt
      (installation_id,branch_id,checkout_id,order_id,method,amount,actor_id,request_id)
    VALUES($1,$2,$3,$4,$5,$6::numeric,$7,$8) RETURNING id`,
    [t,b,checkoutId,saleId,method,amount.toString(),c.actorId,c.requestId]);
   await db.query(`INSERT INTO payment_allocation
     (installation_id,branch_id,receipt_id,sale_ledger_id,allocated)
    VALUES($1,$2,$3,$4,$5::numeric)`,
    [t,b,receipt.rows[0]!.id,saleLedgerId,amount.toString()]);
   await db.query(`INSERT INTO customer_receivable_ledger
    (installation_id,branch_id,customer_id,order_id,kind,source_id,amount,actor_id,request_id)
    VALUES($1,$2,$3,$4,'PAYMENT',$5,-$6::numeric,$7,$8)`,
    [t,b,i.customerId,saleId,receipt.rows[0]!.id,amount.toString(),c.actorId,c.requestId]);
  }
 }
 const updated=await db.query<{revision:string}>(`
  UPDATE sales_order SET fulfillment_status='COMPLETED',
   delivery_status='DELIVERED',payment_status='PAID',
   revision=revision+1,updated_at=now()
  WHERE installation_id=$1 AND branch_id=$2 AND id=$3 RETURNING revision::text`,[t,b,saleId]);
 return {status:201,body:{id:checkoutId,orderId:saleId,branchId:b,
   documentNo:confirmed.body.documentNo,total:total.toString(),
   cashReceived:cash.toString(),bankAmount:bank.toString(),changeDue:change.toString(),
   revision:Number(updated.rows[0]!.revision),paymentStatus:"PAID",
   deliveryStatus:"DELIVERED",fulfillmentStatus:"COMPLETED"}};
}
async function returned(db:PoolClient,c:MutationContext,input:{
 branchId:string;warehouseId:string;shiftId:string;checkoutId:string;refundMethod:string;
}){
 const {branchId:b,warehouseId:w,shiftId,checkoutId,refundMethod}=input,t=c.installationId;
 await warehouseLock(db,t,b,w);
 await requireShift(db,c,b,w,shiftId);
 const record=await db.query<{order_id:string;fulfillment_id:string;customer_id:string;
  grand_total:string;warehouse_id:string}>(`
  SELECT order_id,fulfillment_id,customer_id,grand_total::text,warehouse_id
  FROM retail_checkout WHERE installation_id=$1 AND branch_id=$2 AND id=$3 FOR SHARE`,
  [t,b,checkoutId]);
 const x=record.rows[0];
 if(!x||x.warehouse_id!==w)throw new PosFault(404,"POS_RETURN_NOT_ALLOWED");
 if((await db.query(`SELECT 1 FROM retail_return
  WHERE installation_id=$1 AND branch_id=$2 AND checkout_id=$3`,
  [t,b,checkoutId])).rowCount)throw new PosFault(409,"RETURN_ALREADY_POSTED");
 const rid=randomUUID();
 const movements=await db.query<{id:string;product_id:string;source_line:number;delta_base:string}>(`
  SELECT id,product_id,source_line,delta_base::text FROM inventory_ledger
  WHERE installation_id=$1 AND branch_id=$2 AND warehouse_id=$3
   AND source_type='FULFILLMENT' AND source_id=$4 AND kind='ISSUE'
  ORDER BY source_line`,[t,b,w,x.fulfillment_id]);
 if(!movements.rowCount)throw new PosFault(409,"FULFILLMENT_NOT_FOUND");
 for(const movement of movements.rows)await db.query(`
  INSERT INTO inventory_ledger(installation_id,branch_id,warehouse_id,product_id,kind,
    source_type,source_id,source_line,delta_base,reversal_of,actor_id,request_id)
  VALUES($1,$2,$3,$4,'REVERSAL','REVERSAL',$5,$6,-$7::numeric,$8,$9,$10)`,
  [t,b,w,movement.product_id,rid,movement.source_line,movement.delta_base,movement.id,c.actorId,c.requestId]);
 await db.query(`INSERT INTO retail_return
  (installation_id,branch_id,id,checkout_id,order_id,shift_id,
   amount,refund_method,actor_id,request_id)
  VALUES($1,$2,$3,$4,$5,$6,$7::numeric,$8,$9,$10)`,
  [t,b,rid,checkoutId,x.order_id,shiftId,x.grand_total,refundMethod,c.actorId,c.requestId]);
 if(BigInt(x.grand_total)>0n){
  for(const [kind,amount] of [["RETURN","-"+x.grand_total],["REFUND",x.grand_total]] as const)
   await db.query(`INSERT INTO customer_receivable_ledger
    (installation_id,branch_id,customer_id,order_id,kind,source_id,amount,actor_id,request_id)
    VALUES($1,$2,$3,$4,$5,$6,$7::numeric,$8,$9)`,
    [t,b,x.customer_id,x.order_id,kind,rid,amount,c.actorId,c.requestId]);
 }
 return {status:201,body:{id:rid,checkoutId,orderId:x.order_id,
  amount:x.grand_total,refundMethod,status:"RETURNED"}};
}

async function shiftCash(db:PoolClient,t:string,b:string,id:string){
 const x=await db.query<{expected:string}>(`
 SELECT (s.opening_cash+
   COALESCE((SELECT sum(c.cash_received-c.change_due) FROM retail_checkout c
      WHERE c.installation_id=s.installation_id AND c.branch_id=s.branch_id
        AND c.shift_id=s.id),0)
   -COALESCE((SELECT sum(r.amount) FROM retail_return r
      WHERE r.installation_id=s.installation_id AND r.branch_id=s.branch_id
        AND r.shift_id=s.id AND r.refund_method='CASH'),0))::text AS expected
 FROM retail_shift s WHERE s.installation_id=$1 AND s.branch_id=$2 AND s.id=$3`,
 [t,b,id]);
 return x.rows[0]?.expected??"0";
}
async function checkoutRead(db:PoolClient,t:string,b:string,id:string){
 const q=await db.query(`
 SELECT c.id,c.order_id AS "orderId",o.document_no AS "documentNo",
 c.customer_id AS "customerId",c.warehouse_id AS "warehouseId",
 c.grand_total::text AS total,c.cash_received::text AS "cashReceived",
 c.bank_amount::text AS "bankAmount",c.change_due::text AS "changeDue",
 c.created_at AS "createdAt",r.id AS "returnId"
 FROM retail_checkout c
 JOIN sales_order o ON o.installation_id=c.installation_id
   AND o.branch_id=c.branch_id AND o.id=c.order_id
 LEFT JOIN retail_return r ON r.installation_id=c.installation_id
   AND r.branch_id=c.branch_id AND r.checkout_id=c.id
 WHERE c.installation_id=$1 AND c.branch_id=$2 AND c.id=$3`,[t,b,id]);
 if(!q.rows[0])throw new PosFault(404,"CHECKOUT_NOT_FOUND");
 const lines=await db.query(`
 SELECT l.product_name AS "productName",l.sku,l.unit_code AS "unitCode",
 l.quantity::text,l.unit_price::text AS "unitPrice",l.line_total::text AS "lineTotal"
 FROM sales_order_line l JOIN retail_checkout c
   ON c.installation_id=l.installation_id AND c.branch_id=l.branch_id AND c.order_id=l.order_id
 WHERE c.installation_id=$1 AND c.branch_id=$2 AND c.id=$3
 ORDER BY l.line_no`,[t,b,id]);
 return {...q.rows[0],lines:lines.rows};
}
export async function handlePosHttp(req:IncomingMessage,res:ServerResponse,
 rid:string,url:URL,opts:IdentityOptions,ready:()=>Promise<boolean>){
 const origin=typeof req.headers.origin==="string"?req.headers.origin:undefined;
 const cors=origin&&origin===opts.allowedOrigin?origin:undefined;
 if(origin&&!cors){fail(res,403,"ORIGIN_DENIED",rid);return;}
 if(req.method==="OPTIONS"){if(!cors)fail(res,403,"ORIGIN_DENIED",rid);
   else respond(res,204,null,rid,cors);return;}
 const t=opts.installationId,pool=opts.pool;
 if(!t||!UUID.test(t)||!pool){fail(res,503,"POS_NOT_CONFIGURED",rid,cors);return;}
 try{
  if(!await ready()||!(await pool.query<{ok:boolean}>(`
   SELECT EXISTS(SELECT 1 FROM schema_migrations
    WHERE version='0023_t6_pos_checkout.sql') AS ok`)).rows[0]?.ok){
   fail(res,503,"POS_MIGRATION_REQUIRED",rid,cors);return;
  }
  const auth=req.headers.authorization;
  const token=typeof auth==="string"?/^Bearer ([A-Za-z0-9_-]{43})$/.exec(auth)?.[1]:undefined;
  const dbc=await pool.connect();
  let actor:string|undefined;
  try{actor=token?(await resolveSession(dbc,t,token))?.actorId:undefined;}
  finally{dbc.release();}
  if(!actor){fail(res,401,"AUTH_REQUIRED",rid,cors);return;}
  if(req.method==="GET"&&url.pathname==="/v1/pos/shifts/current"){
   const b=id(url.searchParams.get("branchId")),w=id(url.searchParams.get("warehouseId"));
   const db=await pool.connect();
   try{
    const c={installationId:t,actorId:actor,requestId:rid,action:"pos.shift.read",
      idempotencyKey:"read",expectedRevision:0,payload:{}};
    if(!await perm(db,c,b,w,["pos.shift"]))throw new PosFault(403,"FORBIDDEN");
    const q=await db.query<{id:string;counter_name:string;opening_cash:string}>(`
      SELECT id,counter_name,opening_cash::text FROM retail_shift WHERE
       installation_id=$1 AND branch_id=$2 AND warehouse_id=$3 AND actor_id=$4 AND status='OPEN'
       ORDER BY opened_at DESC LIMIT 1`,[t,b,w,actor]);
    const shift=q.rows[0]??null;
    respond(res,200,{shift:shift?{id:shift.id,counterName:shift.counter_name,
     openingCash:shift.opening_cash,expectedCash:await shiftCash(db,t,b,shift.id)}:null},rid,cors);
   }finally{db.release();}
   return;
  }
  if(req.method==="POST"&&url.pathname==="/v1/pos/shifts/open"){
   const v=await body(req);only(v,["branchId","warehouseId","counterName","openingCash"]);
   const b=id(v.branchId),w=id(v.warehouseId),openingCash=money(v.openingCash);
   const counterName=v.counterName;
   if(typeof counterName!=="string"||!counterName.trim()||counterName.length>80)
    throw new PosFault(400,"INVALID_COUNTER");
   const c=mutation(req,rid,t,actor,"pos.shift.open",{branchId:b,warehouseId:w,counterName:counterName.trim(),openingCash});
   const output=await executeMutation(pool,c,{
    authorize:(db,ctx)=>perm(db,ctx,b,w,["pos.shift"]),
    execute:async(db,ctx)=>{
     await warehouseLock(db,t,b,w);
     const q=await db.query<{id:string}>(`
      INSERT INTO retail_shift(installation_id,branch_id,warehouse_id,actor_id,counter_name,opening_cash)
      VALUES($1,$2,$3,$4,$5,$6::numeric) RETURNING id`,
      [t,b,w,actor,counterName.trim(),openingCash]);
     return {status:201,body:{id:q.rows[0]!.id,status:"OPEN",counterName:counterName.trim(),
       openingCash}};
    },
   });
   respond(res,output.status,output.body,rid,cors);return;
  }
  const closing=/^\/v1\/pos\/shifts\/([0-9a-f-]{36})\/close$/.exec(url.pathname);
  if(req.method==="POST"&&closing){
   const v=await body(req);only(v,["branchId","warehouseId","closingCash"]);
   const b=id(v.branchId),w=id(v.warehouseId),shiftId=id(closing[1]),
    closingCash=money(v.closingCash);
   const c=mutation(req,rid,t,actor,"pos.shift.close",{branchId:b,warehouseId:w,shiftId,closingCash});
   const output=await executeMutation(pool,c,{
    authorize:(db,ctx)=>perm(db,ctx,b,w,["pos.shift"]),
    execute:async(db,ctx)=>{
     await warehouseLock(db,t,b,w);await requireShift(db,ctx,b,w,shiftId);
     const expected=await shiftCash(db,t,b,shiftId);
     await db.query(`UPDATE retail_shift SET status='CLOSED',closed_at=now(),closing_cash=$4::numeric
       WHERE installation_id=$1 AND branch_id=$2 AND id=$3`,[t,b,shiftId,closingCash]);
     return {status:200,body:{id:shiftId,status:"CLOSED",expectedCash:expected,closingCash,
       variance:(BigInt(closingCash)-BigInt(expected)).toString()}};
    },
   });
   respond(res,output.status,output.body,rid,cors);return;
  }
  if(req.method==="POST"&&url.pathname==="/v1/pos/recovery"){
   const v=await body(req);only(v,["checkout"]);
   const input=checkoutInput(record(v.checkout));
   const c=mutation(req,rid,t,actor,"pos.checkout",input);
   const receipt=await readCommittedMutation(pool,c,(db,ctx)=>perm(db,ctx,
     input.branchId,input.warehouseId,["pos.checkout","orders.create","orders.confirm","inventory.post"]));
   respond(res,200,{receipt:receipt?.body??null,requestId:rid},rid,cors);
   return;
  }
  if(req.method==="POST"&&url.pathname==="/v1/pos/checkouts"){
   const input=checkoutInput(await body(req));
   const c=mutation(req,rid,t,actor,"pos.checkout",input);
   const result=await executeMutation(pool,c,{
    authorize:(db,ctx)=>perm(db,ctx,input.branchId,input.warehouseId,
      ["pos.checkout","orders.create","orders.confirm","inventory.post"]),
    execute:(db,ctx)=>checkout(db,ctx,input),
   });
   respond(res,result.status,result.body,rid,cors);return;
  }
  if(req.method==="POST"&&url.pathname==="/v1/pos/returns"){
   const v=await body(req);
   only(v,["branchId","warehouseId","shiftId","checkoutId","refundMethod"]);
   const input={branchId:id(v.branchId),warehouseId:id(v.warehouseId),
    shiftId:id(v.shiftId),checkoutId:id(v.checkoutId),
    refundMethod:v.refundMethod};
   if(!["CASH","BANK_TRANSFER"].includes(String(input.refundMethod)))
    throw new PosFault(400,"INVALID_REFUND_METHOD");
   const c=mutation(req,rid,t,actor,"pos.return",input);
   const result=await executeMutation(pool,c,{
    authorize:(db,ctx)=>perm(db,ctx,input.branchId,input.warehouseId,
      ["pos.return","inventory.post"]),
    execute:(db,ctx)=>returned(db,ctx,{...input,refundMethod:input.refundMethod as string}),
   });
   respond(res,result.status,result.body,rid,cors);return;
  }
  if(req.method==="GET"&&url.pathname==="/v1/pos/checkouts"){
   const b=id(url.searchParams.get("branchId")),w=id(url.searchParams.get("warehouseId"));
   const db=await pool.connect();
   try{
    const c={installationId:t,actorId:actor,requestId:rid,action:"pos.checkout.list",
      idempotencyKey:"read",expectedRevision:0,payload:{}};
    if(!await perm(db,c,b,w,["pos.checkout"]))throw new PosFault(403,"FORBIDDEN");
    const list=await db.query(`SELECT c.id,c.order_id AS "orderId",o.document_no AS "documentNo",
      c.grand_total::text AS total,c.created_at AS "createdAt",
      (r.id IS NOT NULL) AS returned
      FROM retail_checkout c JOIN sales_order o ON o.installation_id=c.installation_id
       AND o.branch_id=c.branch_id AND o.id=c.order_id
      LEFT JOIN retail_return r ON r.installation_id=c.installation_id
       AND r.branch_id=c.branch_id AND r.checkout_id=c.id
      WHERE c.installation_id=$1 AND c.branch_id=$2 AND c.warehouse_id=$3
      ORDER BY c.created_at DESC,c.id DESC LIMIT 50`,[t,b,w]);
    respond(res,200,{items:list.rows},rid,cors);
   }finally{db.release();}
   return;
  }
  const read=/^\/v1\/pos\/checkouts\/([0-9a-f-]{36})$/.exec(url.pathname);
  if(req.method==="GET"&&read){
   const b=id(url.searchParams.get("branchId")),w=id(url.searchParams.get("warehouseId"));
   const db=await pool.connect();
   try{
    const c={installationId:t,actorId:actor,requestId:rid,action:"pos.checkout.read",
      idempotencyKey:"read",expectedRevision:0,payload:{}};
    if(!await perm(db,c,b,w,["pos.checkout"]))throw new PosFault(403,"FORBIDDEN");
    const item=await checkoutRead(db,t,b,id(read[1]));
    if(item.warehouseId!==w)throw new PosFault(404,"CHECKOUT_NOT_FOUND");
    respond(res,200,{receipt:item},rid,cors);
   }finally{db.release();}
   return;
  }
  fail(res,404,"NOT_FOUND",rid,cors);
 }catch(e){
  if(e instanceof PosFault){fail(res,e.status,e.code,rid,cors);return;}
  if(e instanceof MutationFault){fail(res,e.httpStatus,e.code,rid,cors);return;}
  if(typeof e==="object"&&e!==null&&"code" in e){
   if(e.code==="23505"){fail(res,409,"DUPLICATE_POS_DOCUMENT",rid,cors);return;}
   if(e.code==="23503"){fail(res,409,"INVALID_SCOPE",rid,cors);return;}
   if(e.code==="23514"){fail(res,409,"INVALID_POS_STATE",rid,cors);return;}
   if(e.code==="P0001"){fail(res,409,"INSUFFICIENT_STOCK",rid,cors);return;}
  }
  // Do not leak database, actor or token details to clients.
  fail(res,503,"POS_UNAVAILABLE",rid,cors);
 }
}
