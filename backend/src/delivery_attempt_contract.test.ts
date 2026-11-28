import test from "node:test";
import assert from "node:assert/strict";
import {reconcileAttempt,type DispatchSource,type AttemptInput} from "./delivery_attempt_contract.ts";
import {DeliveryTripFault} from "./delivery_trip.ts";

const a="11111111-1111-4111-8111-111111111111";
const b="22222222-2222-4222-8222-222222222222";
const time="2026-11-28T03:00:00.000Z";
const sources:DispatchSource[]=[
 {dispatchId:a,sourceLine:1,issuedBase:"3.123456",baseUnitAllowsFractional:true},
 {dispatchId:b,sourceLine:1,issuedBase:"2",baseUnitAllowsFractional:false}
];
const line=(dispatchId:string,deliveredBase:string)=>({dispatchId,sourceLine:1,deliveredBase});
function rejects(input:AttemptInput,code:string,source=sources){
 assert.throws(()=>reconcileAttempt(source,input,time),
  (e:unknown)=>e instanceof DeliveryTripFault&&e.code===code);
}
test("T5-D full derives exact quantities from issued facts, including split dispatches",()=>{
 const result=reconcileAttempt(sources,{result:"DELIVERED_FULL"},time);
 assert.deepEqual(result.lines.map(x=>[x.deliveredBase,x.remainingOnVehicleBase]),
  [["3.123456","0.000000"],["2.000000","0.000000"]]);
 assert.equal(result.hasRemaining,false);
 rejects({result:"DELIVERED_FULL",lines:[line(a,"1")]},"DELIVERY_ATTEMPT_LINES_FORBIDDEN");
});
test("T5-D partial requires exact line set and retains residual custody without rounding",()=>{
 const result=reconcileAttempt(sources,{result:"DELIVERED_PARTIAL",lines:[line(b,"0"),line(a,"3.123455")]},time);
 assert.deepEqual(result.lines.map(x=>x.remainingOnVehicleBase),["0.000001","2.000000"]);
 assert.equal(result.hasDelivered,true);assert.equal(result.hasRemaining,true);
 rejects({result:"DELIVERED_PARTIAL",lines:[line(a,"1")]},"DELIVERY_ATTEMPT_LINE_SET_MISMATCH");
 rejects({result:"DELIVERED_PARTIAL",lines:[line(a,"1"),line(a,"1")]},"DELIVERY_ATTEMPT_LINE_SET_MISMATCH");
 rejects({result:"DELIVERED_PARTIAL",lines:[line(a,"1"),line("33333333-3333-4333-8333-333333333333","1")]},"DELIVERY_ATTEMPT_LINE_SET_MISMATCH");
 rejects({result:"DELIVERED_PARTIAL",lines:[line(a,"3.123457"),line(b,"0")]},"DELIVERY_ATTEMPT_EXCEEDS_ISSUED");
 for(const bad of ["-1","1e-6","0.0000001","NaN","Infinity","01"])
  rejects({result:"DELIVERED_PARTIAL",lines:[line(a,bad),line(b,"0")]},"DELIVERY_ATTEMPT_QUANTITY_INVALID");
 rejects({result:"DELIVERED_PARTIAL",lines:[line(a,"0"),line(b,"0")]},"DELIVERY_ATTEMPT_PARTIAL_INVALID");
 rejects({result:"DELIVERED_PARTIAL",lines:[line(a,"3.123456"),line(b,"2")]},"DELIVERY_ATTEMPT_PARTIAL_INVALID");
 rejects({result:"DELIVERED_PARTIAL",lines:[line(a,"1"),line(b,"1.5")]},"DELIVERY_ATTEMPT_FRACTION_NOT_ALLOWED");
});
test("T5-D failed and rescheduled retain all issued goods, require reason and future schedule",()=>{
 const failed=reconcileAttempt(sources,{result:"FAILED",reasonCode:"CUSTOMER_ABSENT"},time);
 assert.deepEqual(failed.lines.map(x=>[x.deliveredBase,x.remainingOnVehicleBase]),
  [["0.000000","3.123456"],["0.000000","2.000000"]]);
 assert.equal(failed.hasDelivered,false);
 const later=reconcileAttempt(sources,{result:"RESCHEDULED",reasonCode:"REQUESTED_NEW_TIME",
  rescheduledFor:"2026-11-29T03:00:00.000Z"},time);
 assert.equal(later.hasRemaining,true);
 rejects({result:"FAILED"},"DELIVERY_ATTEMPT_REASON_REQUIRED");
 rejects({result:"FAILED",reasonCode:"ABSENT",lines:[line(a,"0")]},"DELIVERY_ATTEMPT_LINES_FORBIDDEN");
 rejects({result:"RESCHEDULED",reasonCode:"ABSENT",rescheduledFor:time},"DELIVERY_ATTEMPT_RESCHEDULE_TIME_INVALID");
 rejects({result:"RESCHEDULED",reasonCode:"ABSENT",rescheduledFor:"2026-11-31T03:00:00.000Z"},"DELIVERY_ATTEMPT_TIME_INVALID");
 rejects({result:"RESCHEDULED",reasonCode:"ABSENT",rescheduledFor:"2026-11-29T03:00:00"},"DELIVERY_ATTEMPT_TIME_INVALID");
});
test("T5-D missing or corrupt canonical dispatch source fails closed",()=>{
 rejects({result:"DELIVERED_FULL"},"DELIVERY_ATTEMPT_SOURCE_REQUIRED",[]);
 rejects({result:"DELIVERED_FULL"},"DELIVERY_ATTEMPT_SOURCE_INVALID",[sources[0]!,sources[0]!]);
 rejects({result:"DELIVERED_FULL"},"DELIVERY_ATTEMPT_SOURCE_INVALID",[{...sources[1]!,issuedBase:"1.1"}]);
 rejects({result:"DELIVERED_FULL"},"DELIVERY_ATTEMPT_SOURCE_INVALID",[{...sources[0]!,issuedBase:"0"}]);
 rejects({result:"DELIVERED_FULL"},"DELIVERY_ATTEMPT_QUANTITY_INVALID",[{...sources[0]!,issuedBase:"NaN"}]);
});
