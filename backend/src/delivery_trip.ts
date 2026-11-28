import type {PoolClient} from "pg";
import {requireRevision,type MutationContext} from "./mutation.ts";
export class DeliveryTripFault extends Error {
 readonly httpStatus:number;
 readonly code:string;
 constructor(httpStatus:number,code:string){super(code);this.httpStatus=httpStatus;this.code=code;}
}
export type TripScope={branchId:string;warehouseId:string};
type TripRow={id:string;status:string;revision:string;vehicle_id:string|null;driver_id:string|null};
const bad=(code:string)=>new DeliveryTripFault(409,code);
async function locked(db:PoolClient,c:MutationContext,s:TripScope,id:string){
 const q=await db.query<TripRow>(`SELECT id,status,revision::text,vehicle_id,driver_id FROM delivery_trip
 WHERE installation_id=$1 AND branch_id=$2 AND warehouse_id=$3 AND id=$4 FOR UPDATE`,
 [c.installationId,s.branchId,s.warehouseId,id]);
 if(!q.rows[0])throw new DeliveryTripFault(404,"TRIP_NOT_FOUND");
 requireRevision(c.expectedRevision,Number(q.rows[0].revision));return q.rows[0];
}
async function changed(db:PoolClient,c:MutationContext,s:TripScope,id:string,
 status:string|null=null,vehicle:string|null=null,driver:string|null=null,
 day:string|null=null,note:string|null=null){
 const q=await db.query<{revision:string}>(`UPDATE delivery_trip SET revision=revision+1,
 status=coalesce($5,status),vehicle_id=coalesce($6,vehicle_id),
 driver_id=coalesce($7,driver_id),planned_date=coalesce($8::date,planned_date),
 note=coalesce($9,note),updated_at=now()
 WHERE installation_id=$1 AND branch_id=$2 AND warehouse_id=$3 AND id=$4
 RETURNING revision::text`,[c.installationId,s.branchId,s.warehouseId,id,status,vehicle,driver,day,note]);
 return Number(q.rows[0]!.revision);
}
async function event(db:PoolClient,c:MutationContext,s:TripScope,id:string,type:string,revision:number,count=0){
 await db.query(`INSERT INTO delivery_trip_event
 (installation_id,branch_id,trip_id,event_type,revision,detail,actor_id,request_id)
 VALUES($1,$2,$3,$4,$5,jsonb_build_object('count',$6::integer),$7,$8)`,
 [c.installationId,s.branchId,id,type,revision,count,c.actorId,c.requestId]);
}
export async function tripResources(db:PoolClient,t:string,s:TripScope,type:"drivers"|"vehicles"){
 if(type==="vehicles")return (await db.query(`SELECT id,code,name,active,
  license_plate AS "licensePlate" FROM delivery_vehicle WHERE
  installation_id=$1 AND branch_id=$2 AND warehouse_id=$3
  ORDER BY active DESC,code LIMIT 200`,[t,s.branchId,s.warehouseId])).rows;
 // Legacy 0027 drivers remain visible for reconciliation, but unlinked drivers
 // must never be considered eligible for a new plan or locked trip.
 return (await db.query(`SELECT d.id,COALESCE(e.code,d.code) AS code,
  COALESCE(e.full_name,d.name) AS name,COALESCE(e.phone,d.phone) AS phone,
  d.employee_id AS "employeeId",(d.active AND COALESCE(e.active,false)) AS active,
  (e.id IS NOT NULL) AS "linkedEmployee"
  FROM delivery_driver d LEFT JOIN org_employee e ON
   e.installation_id=d.installation_id AND e.branch_id=d.branch_id
   AND e.id=d.employee_id
  WHERE d.installation_id=$1 AND d.branch_id=$2 AND d.warehouse_id=$3
  ORDER BY (d.active AND COALESCE(e.active,false)) DESC,d.code
  LIMIT 200`,[t,s.branchId,s.warehouseId])).rows;
}
export async function createResource(db:PoolClient,c:MutationContext,s:TripScope,
 kind:"vehicles",v:{code:string;name:string;licensePlate:string}){
 requireRevision(c.expectedRevision,0);
 const q=await db.query(`INSERT INTO delivery_vehicle
  (installation_id,branch_id,warehouse_id,code,name,license_plate,created_by)
  VALUES($1,$2,$3,$4,$5,$6,$7) RETURNING id,code,name,active`,
 [c.installationId,s.branchId,s.warehouseId,v.code,v.name,v.licensePlate,c.actorId]);
 return {status:201,body:{resource:q.rows[0]}};
}
export async function tripList(db:PoolClient,t:string,s:TripScope,offset=0){
 return (await db.query(`SELECT t.id,t.trip_no AS "tripNo",t.status,t.revision::integer,
 t.planned_date::text AS "plannedDate",t.note,t.vehicle_id AS "vehicleId",
 t.driver_id AS "driverId",d.name AS "driverName",
 v.license_plate AS "licensePlate",count(st.order_id)::integer AS "stopCount"
 FROM delivery_trip t LEFT JOIN delivery_driver d ON
  d.installation_id=t.installation_id AND d.branch_id=t.branch_id AND d.id=t.driver_id
 LEFT JOIN delivery_vehicle v ON v.installation_id=t.installation_id
  AND v.branch_id=t.branch_id AND v.id=t.vehicle_id
 LEFT JOIN delivery_trip_stop st ON st.installation_id=t.installation_id
  AND st.branch_id=t.branch_id AND st.trip_id=t.id
 WHERE t.installation_id=$1 AND t.branch_id=$2 AND t.warehouse_id=$3
 GROUP BY t.installation_id,t.branch_id,t.id,d.name,v.license_plate
 ORDER BY t.created_at DESC,t.id DESC LIMIT 100 OFFSET $4`,
 [t,s.branchId,s.warehouseId,offset])).rows;
}
export async function tripEligible(db:PoolClient,t:string,s:TripScope,offset=0,search=''){
 return (await db.query(`SELECT o.id,o.document_no AS "documentNo",
 v.customer_name AS "customerName",v.grand_total::text AS total,
 c.delivery_address AS "deliveryAddress",c.requested_delivery_date::text AS "deliveryDate"
 FROM sales_order o JOIN sales_order_version v ON
  v.installation_id=o.installation_id AND v.branch_id=o.branch_id
  AND v.order_id=o.id AND v.version_no=o.current_version
 JOIN sales_order_version_context c ON c.installation_id=v.installation_id
  AND c.branch_id=v.branch_id AND c.order_id=v.order_id AND c.version_no=v.version_no
 WHERE o.installation_id=$1 AND o.branch_id=$2 AND c.warehouse_id=$3
  AND o.status='CONFIRMED' AND v.state='CONFIRMED' AND c.delivery_choice='TRIP'
  AND c.delivery_address IS NOT NULL AND btrim(c.delivery_address)<>''
  AND o.delivery_status='NOT_DISPATCHED' AND o.payment_status='NOT_DUE'
  AND o.fulfillment_status<>'COMPLETED'
  AND NOT EXISTS(SELECT 1 FROM delivery_trip_stop s WHERE
   s.installation_id=o.installation_id AND s.branch_id=o.branch_id AND s.order_id=o.id)
  AND ($4::text='' OR o.document_no ILIKE '%'||$4||'%'
   OR v.customer_name ILIKE '%'||$4||'%'
   OR c.delivery_address ILIKE '%'||$4||'%')
 ORDER BY o.created_at,o.id LIMIT 200 OFFSET $5`,
 [t,s.branchId,s.warehouseId,search,offset])).rows;
}
export async function tripDetail(db:PoolClient,t:string,s:TripScope,id:string){
 const h=await db.query(`SELECT t.id,t.trip_no AS "tripNo",t.status,t.revision::integer,
 t.planned_date::text AS "plannedDate",t.note,t.vehicle_id AS "vehicleId",
 t.driver_id AS "driverId",d.name AS "driverName",v.license_plate AS "licensePlate"
 FROM delivery_trip t LEFT JOIN delivery_driver d ON
  d.installation_id=t.installation_id AND d.branch_id=t.branch_id AND d.id=t.driver_id
 LEFT JOIN delivery_vehicle v ON v.installation_id=t.installation_id
  AND v.branch_id=t.branch_id AND v.id=t.vehicle_id
 WHERE t.installation_id=$1 AND t.branch_id=$2 AND t.warehouse_id=$3 AND t.id=$4`,
 [t,s.branchId,s.warehouseId,id]);
 if(!h.rows[0])throw new DeliveryTripFault(404,"TRIP_NOT_FOUND");
 const stops=await db.query(`SELECT st.order_id AS "orderId",st.order_version AS version,
 st.sequence_no AS "sequenceNo",st.customer_name AS "customerName",
 st.delivery_address AS "deliveryAddress",o.document_no AS "documentNo",
 v.grand_total::text AS total
 FROM delivery_trip_stop st JOIN sales_order o
  ON o.installation_id=st.installation_id AND o.branch_id=st.branch_id AND o.id=st.order_id
 JOIN sales_order_version v ON v.installation_id=st.installation_id AND
  v.branch_id=st.branch_id AND v.order_id=st.order_id AND v.version_no=st.order_version
 WHERE st.installation_id=$1 AND st.branch_id=$2 AND st.trip_id=$3
 ORDER BY st.sequence_no,st.order_id`,[t,s.branchId,id]);
 return {...h.rows[0],stops:stops.rows};
}
export async function createTrip(db:PoolClient,c:MutationContext,s:TripScope,
 day:string,note:string){
 requireRevision(c.expectedRevision,0);
 const n=await db.query<{next_value:number}>(`INSERT INTO delivery_trip_counter
 (installation_id,branch_id,business_day,next_value) VALUES($1,$2,$3::date,1)
 ON CONFLICT (installation_id,branch_id,business_day)
 DO UPDATE SET next_value=delivery_trip_counter.next_value+1
 RETURNING next_value`,[c.installationId,s.branchId,day]);
 const num=n.rows[0]!.next_value;
 if(num>999999)throw bad("TRIP_NUMBER_EXHAUSTED");
 const tripNo="TG-"+day.replaceAll("-","")+"-"+String(num).padStart(6,"0");
 const q=await db.query<{id:string}>(`INSERT INTO delivery_trip
 (installation_id,branch_id,warehouse_id,trip_no,planned_date,note,created_by)
 VALUES($1,$2,$3,$4,$5::date,$6,$7) RETURNING id`,
 [c.installationId,s.branchId,s.warehouseId,tripNo,day,note,c.actorId]);
 const tripId=q.rows[0]!.id;
 await event(db,c,s,tripId,"CREATED",0);
 return {status:201,body:{id:tripId,tripNo,status:"DRAFT",revision:0}};
}
async function candidate(db:PoolClient,c:MutationContext,s:TripScope,id:string){
 const q=await db.query<{id:string;version:number;customer_id:string;
 customer_name:string;delivery_address:string}>(`SELECT o.id,
 o.current_version AS version,o.customer_id,v.customer_name,c.delivery_address
 FROM sales_order o JOIN sales_order_version v ON v.installation_id=o.installation_id
 AND v.branch_id=o.branch_id AND v.order_id=o.id AND v.version_no=o.current_version
 JOIN sales_order_version_context c ON c.installation_id=v.installation_id
 AND c.branch_id=v.branch_id AND c.order_id=v.order_id AND c.version_no=v.version_no
 WHERE o.installation_id=$1 AND o.branch_id=$2 AND o.id=$3 AND
 o.status='CONFIRMED' AND v.state='CONFIRMED'
 AND o.delivery_status='NOT_DISPATCHED' AND o.payment_status='NOT_DUE'
 AND o.fulfillment_status<>'COMPLETED' AND c.delivery_choice='TRIP'
 AND c.warehouse_id=$4 AND c.delivery_address IS NOT NULL
 AND btrim(c.delivery_address)<>'' FOR UPDATE OF o`,
 [c.installationId,s.branchId,id,s.warehouseId]);
 if(!q.rows[0])throw bad("ORDER_NOT_ELIGIBLE_FOR_TRIP");
 return q.rows[0];
}
export async function assignOrders(db:PoolClient,c:MutationContext,s:TripScope,tripId:string,ids:string[]){
 const tr=await locked(db,c,s,tripId);
 if(tr.status!=="DRAFT")throw bad("TRIP_NOT_DRAFT");
 const n=await db.query<{n:string}>(`SELECT count(*)::text AS n FROM delivery_trip_stop
 WHERE installation_id=$1 AND branch_id=$2 AND trip_id=$3`,
 [c.installationId,s.branchId,tripId]);
 let seq=Number(n.rows[0]!.n);
 for(const id of [...ids].sort()){
  const x=await candidate(db,c,s,id);
  if(++seq>200)throw bad("TRIP_STOP_LIMIT");
  await db.query(`INSERT INTO delivery_trip_stop
  (installation_id,branch_id,trip_id,order_id,order_version,sequence_no,
  customer_id,customer_name,delivery_address)
  VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9)`,
  [c.installationId,s.branchId,tripId,id,x.version,seq,
   x.customer_id,x.customer_name,x.delivery_address]);
 }
 const revision=await changed(db,c,s,tripId);
 await event(db,c,s,tripId,"ASSIGNED",revision,ids.length);
 return {status:200,body:{id:tripId,revision,assigned:ids.length}};
}
export async function removeOrders(db:PoolClient,c:MutationContext,s:TripScope,tripId:string,ids:string[]){
 const tr=await locked(db,c,s,tripId);
 if(tr.status!=="DRAFT")throw bad("TRIP_NOT_DRAFT");
 const d=await db.query(`DELETE FROM delivery_trip_stop WHERE installation_id=$1
 AND branch_id=$2 AND trip_id=$3 AND order_id=ANY($4::uuid[]) RETURNING order_id`,
 [c.installationId,s.branchId,tripId,ids]);
 if(d.rowCount!==ids.length)throw bad("TRIP_STOP_CHANGED");
 const rows=await db.query<{order_id:string}>(`SELECT order_id FROM delivery_trip_stop
 WHERE installation_id=$1 AND branch_id=$2 AND trip_id=$3 ORDER BY sequence_no`,
 [c.installationId,s.branchId,tripId]);
 for(let i=0;i<rows.rows.length;i++)await db.query(`UPDATE delivery_trip_stop
 SET sequence_no=$4 WHERE installation_id=$1 AND branch_id=$2 AND
 trip_id=$3 AND order_id=$5`,
 [c.installationId,s.branchId,tripId,i+1,rows.rows[i]!.order_id]);
 const revision=await changed(db,c,s,tripId);
 await event(db,c,s,tripId,"UNASSIGNED",revision,ids.length);
 return {status:200,body:{id:tripId,revision,removed:ids.length}};
}
export async function reorder(db:PoolClient,c:MutationContext,s:TripScope,tripId:string,ids:string[]){
 const tr=await locked(db,c,s,tripId);
 if(tr.status!=="DRAFT")throw bad("TRIP_NOT_DRAFT");
 const q=await db.query<{order_id:string}>(`SELECT order_id FROM delivery_trip_stop
 WHERE installation_id=$1 AND branch_id=$2 AND trip_id=$3 FOR UPDATE`,
 [c.installationId,s.branchId,tripId]);
 if(q.rows.length!==ids.length||q.rows.length===0||
 q.rows.some(x=>!ids.includes(x.order_id)))throw bad("TRIP_REORDER_SET_MISMATCH");
 for(let i=0;i<ids.length;i++)await db.query(`UPDATE delivery_trip_stop
 SET sequence_no=$4 WHERE installation_id=$1 AND branch_id=$2
 AND trip_id=$3 AND order_id=$5`,
 [c.installationId,s.branchId,tripId,i+1,ids[i]]);
 const revision=await changed(db,c,s,tripId);
 await event(db,c,s,tripId,"REORDERED",revision,ids.length);
 return {status:200,body:{id:tripId,revision}};
}
async function verifyStops(db:PoolClient,c:MutationContext,s:TripScope,tripId:string){
 // Lock route orders in stable ID order until COMMIT, to serialize LOCK
 // against concurrent amendment/cancellation and fulfillment transitions.
 await db.query(`SELECT o.id FROM delivery_trip_stop st
  JOIN sales_order o ON o.installation_id=st.installation_id AND
   o.branch_id=st.branch_id AND o.id=st.order_id
  WHERE st.installation_id=$1 AND st.branch_id=$2 AND st.trip_id=$3
  ORDER BY o.id FOR UPDATE OF o`,
  [c.installationId,s.branchId,tripId]);
 const badRows=await db.query(`SELECT o.id FROM delivery_trip_stop st
 JOIN sales_order o ON o.installation_id=st.installation_id
 AND o.branch_id=st.branch_id AND o.id=st.order_id
 JOIN sales_order_version v ON v.installation_id=o.installation_id
 AND v.branch_id=o.branch_id AND v.order_id=o.id AND v.version_no=o.current_version
 JOIN sales_order_version_context x ON x.installation_id=v.installation_id
 AND x.branch_id=v.branch_id AND x.order_id=v.order_id AND x.version_no=v.version_no
 WHERE st.installation_id=$1 AND st.branch_id=$2 AND st.trip_id=$3
 AND (o.current_version<>st.order_version OR o.status<>'CONFIRMED'
 OR v.state<>'CONFIRMED' OR x.delivery_choice<>'TRIP' OR x.warehouse_id<>$4
 OR x.delivery_address IS DISTINCT FROM st.delivery_address
 OR o.delivery_status<>'NOT_DISPATCHED' OR o.payment_status<>'NOT_DUE'
 OR o.fulfillment_status='COMPLETED')`,
 [c.installationId,s.branchId,tripId,s.warehouseId]);
 if(badRows.rowCount)throw bad("TRIP_ORDER_CHANGED");
 const n=await db.query<{n:string}>(`SELECT count(*)::text AS n
 FROM delivery_trip_stop WHERE installation_id=$1 AND branch_id=$2 AND trip_id=$3`,
 [c.installationId,s.branchId,tripId]);
 if(Number(n.rows[0]!.n)<1)throw bad("TRIP_EMPTY");
}
export async function transition(db:PoolClient,c:MutationContext,s:TripScope,tripId:string,
 action:"plan"|"reopen"|"lock",vehicleId?:string,driverId?:string,day?:string,note?:string){
 const tr=await locked(db,c,s,tripId);
 if(action==="reopen"){
  if(tr.status!=="PLANNED")throw bad("TRIP_REOPEN_DENIED");
  const revision=await changed(db,c,s,tripId,"DRAFT");
  await event(db,c,s,tripId,"REOPENED",revision);
  return {status:200,body:{id:tripId,status:"DRAFT",revision}};
 }
 if(action==="plan"&&tr.status!=="DRAFT"||
 action==="lock"&&tr.status!=="PLANNED")throw bad("TRIP_TRANSITION_DENIED");
 await verifyStops(db,c,s,tripId);
 const veh=action==="plan"?vehicleId:tr.vehicle_id;
 const drv=action==="plan"?driverId:tr.driver_id;
 if(!veh||!drv)throw bad("TRIP_DRIVER_VEHICLE_REQUIRED");
 const v=await db.query<{ok:boolean}>(`SELECT EXISTS(SELECT 1 FROM delivery_vehicle
 WHERE installation_id=$1 AND branch_id=$2 AND warehouse_id=$3
 AND id=$4 AND active) AS ok`,[c.installationId,s.branchId,s.warehouseId,veh]);
 // Employee deactivation locks e FOR UPDATE. Planning locks the same
 // canonical row FOR SHARE, so a concurrent inactive transition cannot race.
 const d=await db.query<{id:string}>(`SELECT e.id FROM delivery_driver d
 JOIN org_employee e ON e.installation_id=d.installation_id
  AND e.branch_id=d.branch_id AND e.id=d.employee_id
 WHERE d.installation_id=$1 AND d.branch_id=$2 AND d.warehouse_id=$3
  AND d.id=$4 AND d.active AND e.active
 FOR SHARE OF e,d`,[c.installationId,s.branchId,s.warehouseId,drv]);
 if(!v.rows[0]?.ok||!d.rowCount)throw bad("TRIP_INACTIVE_RESOURCE");
 const status=action==="plan"?"PLANNED":"LOCKED";
 const revision=await changed(db,c,s,tripId,status,
 action==="plan"?veh:null,action==="plan"?drv:null,day??null,note??null);
 await event(db,c,s,tripId,action==="plan"?"PLANNED":"LOCKED",revision);
 return {status:200,body:{id:tripId,status,revision}};
}
