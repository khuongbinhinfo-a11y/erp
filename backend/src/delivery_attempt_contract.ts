import {stockDecimalUnits,stockUnitsDecimal} from "./inventory.ts";
import {DeliveryTripFault} from "./delivery_trip.ts";

// Adapted from legacy logistics-driver-delivery.js:475-540.
// The input source must be loaded server-side from locked, scoped canonical
// sales_trip_dispatch_line + matching Inventory OUT, never from the client.
// This is a pure validation/quantity contract; it does not post any facts.
export type AttemptResult="DELIVERED_FULL"|"DELIVERED_PARTIAL"|"FAILED"|"RESCHEDULED";
type DispatchKey={dispatchId:string;sourceLine:number};
export type DispatchSource=DispatchKey&{
 issuedBase:string;baseUnitAllowsFractional:boolean;
};
export type AttemptLine=DispatchKey&{deliveredBase:string};
export type AttemptInput={
 result:AttemptResult;reasonCode?:string;rescheduledFor?:string;lines?:AttemptLine[];
};
const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const QUANTITY=/^(0|[1-9][0-9]{0,17})(?:\.[0-9]{1,6})?$/;
const REASON=/^[A-Z][A-Z0-9_]{0,47}$/;
function fail(code:string,status=400):never{throw new DeliveryTripFault(status,code);}
function key(line:DispatchKey,status:number){
 if(typeof line.dispatchId!=="string"||!UUID.test(line.dispatchId)||
  !Number.isInteger(line.sourceLine)||line.sourceLine<1||line.sourceLine>10000)
  fail("DELIVERY_ATTEMPT_SOURCE_INVALID",status);
 return line.dispatchId.toLowerCase()+":"+line.sourceLine;
}
function units(value:string,status:number){
 if(typeof value!=="string"||!QUANTITY.test(value))
  fail("DELIVERY_ATTEMPT_QUANTITY_INVALID",status);
 return stockDecimalUnits(value);
}
function timestamp(value:unknown):number{
 // Require explicit canonical UTC; Date.parse otherwise normalizes invalid
 // calendar dates and interprets ambiguous local times.
 if(typeof value!=="string"||!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(value))
  fail("DELIVERY_ATTEMPT_TIME_INVALID");
 const n=Date.parse(value);
 if(!Number.isFinite(n)||new Date(n).toISOString()!==value)
  fail("DELIVERY_ATTEMPT_TIME_INVALID");
 return n;
}
export function reconcileAttempt(sources:readonly DispatchSource[],input:AttemptInput,
 serverOccurredAt:string){
 const occurred=timestamp(serverOccurredAt);
 if(!["DELIVERED_FULL","DELIVERED_PARTIAL","FAILED","RESCHEDULED"].includes(input.result))
  fail("DELIVERY_ATTEMPT_RESULT_INVALID");
 const successful=input.result==="DELIVERED_FULL"||input.result==="DELIVERED_PARTIAL";
 if(successful){
  if(input.reasonCode!==undefined||input.rescheduledFor!==undefined)
   fail("DELIVERY_ATTEMPT_REASON_FORBIDDEN");
 }else if(typeof input.reasonCode!=="string"||!REASON.test(input.reasonCode))
  fail("DELIVERY_ATTEMPT_REASON_REQUIRED");
 if(input.result==="RESCHEDULED"){
  if(timestamp(input.rescheduledFor)<=occurred)
   fail("DELIVERY_ATTEMPT_RESCHEDULE_TIME_INVALID");
 }else if(input.rescheduledFor!==undefined)
  fail("DELIVERY_ATTEMPT_RESCHEDULE_FORBIDDEN");
 if(!sources.length)fail("DELIVERY_ATTEMPT_SOURCE_REQUIRED",409);
 const issued=new Map<string,bigint>();
 for(const source of sources){
  const k=key(source,409),q=units(source.issuedBase,409);
  if(issued.has(k)||q<=0n||typeof source.baseUnitAllowsFractional!=="boolean")
   fail("DELIVERY_ATTEMPT_SOURCE_INVALID",409);
  if(!source.baseUnitAllowsFractional&&q%1000000n!==0n)
   fail("DELIVERY_ATTEMPT_SOURCE_INVALID",409);
  issued.set(k,q);
 }
 const lines=input.lines??[];
 if(!Array.isArray(lines))fail("DELIVERY_ATTEMPT_LINES_INVALID");
 const requested=new Map<string,bigint>();
 if(input.result==="DELIVERED_PARTIAL"){
  if(lines.length!==sources.length)fail("DELIVERY_ATTEMPT_LINE_SET_MISMATCH");
  for(const line of lines){
   if(!line||typeof line!=="object")fail("DELIVERY_ATTEMPT_LINES_INVALID");
   const k=key(line,400);
   if(!issued.has(k)||requested.has(k))fail("DELIVERY_ATTEMPT_LINE_SET_MISMATCH");
   requested.set(k,units(line.deliveredBase,400));
  }
 }else if(lines.length)fail("DELIVERY_ATTEMPT_LINES_FORBIDDEN");
 let hasDelivered=false,hasRemaining=false;
 const reconciled=sources.map(source=>{
  const k=key(source,409),q=issued.get(k)!;
  const actual=input.result==="DELIVERED_FULL"?q:
   input.result==="DELIVERED_PARTIAL"?requested.get(k)!:0n;
  if(actual>q)fail("DELIVERY_ATTEMPT_EXCEEDS_ISSUED",409);
  if(!source.baseUnitAllowsFractional&&actual%1000000n!==0n)
   fail("DELIVERY_ATTEMPT_FRACTION_NOT_ALLOWED");
  hasDelivered||=actual>0n;hasRemaining||=actual<q;
  return {dispatchId:source.dispatchId.toLowerCase(),sourceLine:source.sourceLine,
   issuedBase:stockUnitsDecimal(q),deliveredBase:stockUnitsDecimal(actual),
   remainingOnVehicleBase:stockUnitsDecimal(q-actual)};
 });
 if(input.result==="DELIVERED_PARTIAL"&&(!hasDelivered||!hasRemaining))
  fail("DELIVERY_ATTEMPT_PARTIAL_INVALID");
 // Residual is custody, NOT a stock IN. Return to warehouse requires a
 // separate actual return fact. Full refers to issued, not ordered quantity.
 return {result:input.result,occurredAt:serverOccurredAt,
  ...(input.reasonCode===undefined?{}:{reasonCode:input.reasonCode}),
  ...(input.rescheduledFor===undefined?{}:{rescheduledFor:input.rescheduledFor}),
  lines:reconciled,hasDelivered,hasRemaining};
}
