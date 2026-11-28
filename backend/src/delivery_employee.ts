import type {PoolClient} from "pg";
import {requireRevision,type MutationContext} from "./mutation.ts";
import {DeliveryTripFault,type TripScope} from "./delivery_trip.ts";

function fail(code:string,status=409):never{
 throw new DeliveryTripFault(status,code);
}
export async function employees(db:PoolClient,installationId:string,branchId:string,offset=0){
 const result=await db.query(`SELECT e.id,e.code,e.full_name AS "fullName",
  e.job_title AS "jobTitle",e.phone,e.active,e.revision::integer,
  EXISTS (SELECT 1 FROM delivery_driver d WHERE
    d.installation_id=e.installation_id AND d.branch_id=e.branch_id
    AND d.employee_id=e.id AND d.active) AS "linkedDriver"
  FROM org_employee e WHERE e.installation_id=$1 AND e.branch_id=$2
  ORDER BY e.active DESC,e.code,e.id LIMIT 200 OFFSET $3`,
  [installationId,branchId,offset]);
 return result.rows;
}
export async function createEmployee(db:PoolClient,c:MutationContext,s:TripScope,
 input:{code:string;fullName:string;phone?:string;jobTitle?:string}){
 requireRevision(c.expectedRevision,0);
 const r=await db.query<{id:string}>(`INSERT INTO org_employee
  (installation_id,branch_id,code,full_name,job_title,phone,created_by)
  VALUES($1,$2,$3,$4,$5,$6,$7) RETURNING id`,
  [c.installationId,s.branchId,input.code,input.fullName,input.jobTitle??null,
   input.phone??null,c.actorId]);
 return {status:201,body:{employee:{id:r.rows[0]!.id,
  code:input.code,fullName:input.fullName,phone:input.phone??null,
  jobTitle:input.jobTitle??null,active:true,revision:0,linkedDriver:false}}};
}
export async function updateEmployee(db:PoolClient,c:MutationContext,s:TripScope,
 employeeId:string,input:{fullName:string;phone?:string;jobTitle?:string;active:boolean}){
 const current=await db.query<{revision:string;active:boolean}>(`
  SELECT revision::text,active FROM org_employee
  WHERE installation_id=$1 AND branch_id=$2 AND id=$3 FOR UPDATE`,
  [c.installationId,s.branchId,employeeId]);
 if(!current.rows[0])fail("EMPLOYEE_NOT_FOUND",404);
 requireRevision(c.expectedRevision,Number(current.rows[0].revision));
 if(!input.active&&current.rows[0].active){
  const pending=await db.query(`SELECT 1 FROM delivery_driver d
   JOIN delivery_trip t ON t.installation_id=d.installation_id
    AND t.branch_id=d.branch_id AND t.warehouse_id=d.warehouse_id
    AND t.driver_id=d.id
   WHERE d.installation_id=$1 AND d.branch_id=$2 AND d.employee_id=$3
    AND t.status IN ('PLANNED','LOCKED') LIMIT 1`,
   [c.installationId,s.branchId,employeeId]);
  if(pending.rowCount)fail("EMPLOYEE_HAS_PENDING_TRIPS");
 }
 const changed=await db.query(`UPDATE org_employee SET
  full_name=$4,phone=$5,job_title=$6,active=$7,
  revision=revision+1,updated_at=now()
  WHERE installation_id=$1 AND branch_id=$2 AND id=$3
  RETURNING id,code,full_name AS "fullName",phone,
   job_title AS "jobTitle",active,revision::integer`,
  [c.installationId,s.branchId,employeeId,input.fullName,input.phone??null,
   input.jobTitle??null,input.active]);
 return {status:200,body:{employee:changed.rows[0]}};
}
export async function linkDriver(db:PoolClient,c:MutationContext,s:TripScope,
 employeeId:string){
 requireRevision(c.expectedRevision,0);
 const employee=await db.query<{
  id:string;code:string;full_name:string;phone:string|null
 }>(`SELECT id,code,full_name,phone FROM org_employee WHERE
  installation_id=$1 AND branch_id=$2 AND id=$3 AND active
  FOR UPDATE`,[c.installationId,s.branchId,employeeId]);
 if(!employee.rows[0])fail("DRIVER_EMPLOYEE_NOT_AVAILABLE");
 const already=await db.query(`SELECT 1 FROM delivery_driver WHERE
  installation_id=$1 AND employee_id=$2 AND active LIMIT 1`,
  [c.installationId,employeeId]);
 if(already.rowCount)fail("DRIVER_EMPLOYEE_ALREADY_LINKED");
 const e=employee.rows[0];
 const result=await db.query(`INSERT INTO delivery_driver
  (installation_id,branch_id,warehouse_id,code,name,phone,employee_id,created_by)
  VALUES($1,$2,$3,$4,$5,$6,$7,$8)
  RETURNING id,code,name,phone,employee_id AS "employeeId",active`,
  [c.installationId,s.branchId,s.warehouseId,e.code,e.full_name,e.phone,
   e.id,c.actorId]);
 return {status:201,body:{resource:result.rows[0]}};
}
