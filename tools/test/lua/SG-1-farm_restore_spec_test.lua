-- Reference bar ported verbatim from the SG-1 delivery package (tracking repo); its trailing T.summary() is supplied by run-tests.mjs.
-- SG-1 farm restore: pure reference, NOT native/gameplay or production.
local function cp(x)
 if type(x)~="table" then return x end
 local y={};for k,v in pairs(x) do y[k]=cp(v) end;return y
end
local function mapping(mp,before,actual,target,special)
 if mp then if next(actual) then return nil end;return {} end
 local want={};for _,id in ipairs(before) do if id~=target and not special[id] then want[id]=target end end
 for k,v in pairs(want) do if actual[k]~=v then return nil end end
 for k,v in pairs(actual) do if want[k]~=v then return nil end end
 return cp(actual)
end
local reserved={[0]=true,[14]=true,[15]=true}
local m=mapping(false,{0,1,2,3,14},{[2]=1,[3]=1},1,reserved)
T.eq("source two maps to actual survivor",m[2],1)
T.eq("source three maps to actual survivor",m[3],1)
T.eq("survivor is not a source mapping",m[1],nil)
T.eq("spectator is excluded",m[0],nil)
T.eq("reserved source is refused",mapping(false,{0,1,2},{[0]=1,[2]=1},1,reserved),nil)
T.eq("unobserved source is refused",mapping(false,{1,2},{[2]=1,[7]=1},1,reserved),nil)
T.eq("wrong destination is refused",mapping(false,{1,2},{[2]=3},1,reserved),nil)
T.eq("MP has no conversion",next(mapping(true,{1,2},{},1,reserved)),nil)
T.eq("MP rejects stale merge map",mapping(true,{1,2},{[2]=1},1,reserved),nil)
local function stage(s)
 if not s.payload or not s.farms or not s.native or s.staged then return false end
 s.staged=true;s.calls=s.calls+1;return true
end
local early={payload=true,farms=false,native=false,calls=0}
T.eq("early payload waits for farms",stage(early),false)
early.farms=true;T.eq("farms alone are not object readiness",stage(early),false)
early.native=true;T.eq("both barriers release candidate",stage(early),true)
stage(early);T.eq("repeat callback stages once",early.calls,1)
local late={payload=false,farms=true,native=true,calls=0}
T.eq("native ready waits for payload",stage(late),false)
late.payload=true;T.eq("late payload uses retained context",stage(late),true)
local function bindings(saved,keys)
 local seen,out={},{}
 for _,r in ipairs(saved) do
  local k=keys[r.key];if not k or seen[k] then return nil end
  seen[k]=true;local n=cp(r);n.key=k;out[#out+1]=n
 end
 return out
end
local stocks={{key="binA",stockId="stockA",generation=7,amount=25,facts={originFarm=2}},
 {key="binB",stockId="stockB",generation=9,amount=40,facts={originFarm=3}}}
local b=bindings(stocks,{binA="sameA",binB="sameB"})
T.eq("same farm does not combine bins",#b,2)
T.eq("stock identity survives rekey",b[1].stockId,"stockA")
T.eq("ownership does not advance content generation",b[1].generation,7)
T.eq("historical farm fact not rewritten",b[1].facts.originFarm,2)
T.eq("native quantities not changed",b[1].amount+b[2].amount,65)
T.eq("binding collision refuses entire set",bindings(stocks,{binA="one",binB="one"}),nil)
T.eq("failed staging does not change source",stocks[1].key,"binA")
local function library(l,map)
 local r=cp(l);if map[r.owner] then r.retired=true end;return r
end
local lib=library({id="L2",owner=2,retired=false,definition="frozen"},m)
T.eq("source library retired",lib.retired,true)
T.eq("library identity retained",lib.id,"L2")
T.eq("library not reassigned",lib.owner,2)
T.eq("referenced definition retained",lib.definition,"frozen")
T.eq("surviving library unchanged",library({id="L1",owner=1,retired=false},m).retired,false)
local function guidance(g,map)
 local r=cp(g)
 if map[r.owner] and r.empty then r.target=nil;r.revision=r.revision+1;r.owner=map[r.owner] end
 return r
end
local armed={owner=2,empty=true,target="L2/R1/4",revision=6}
local g=guidance(armed,m)
T.eq("remapped empty target clears",g.target,nil)
T.eq("selection revision advances once",g.revision,7)
T.eq("retry uses original candidate",guidance(armed,m).revision,7)
T.eq("survivor empty target retained",guidance({owner=1,empty=true,target="own",revision=2},m).target,"own")
T.eq("filled history remains",guidance({owner=2,empty=false,target="bound",revision=6},m).target,"bound")
local function receiptMap(raw,target)
 if type(raw)~="table" or type(target)~="number" or target~=1 then return nil end
 local count=0;for k in pairs(raw) do
  if type(k)~="number" or k%1~=0 or k<1 then return nil end;count=count+1
 end
 local out,last={},0
 for i=1,count do
  local row=raw[i];if type(row)~="table" then return nil end
  local n,v=row.sourceFarmId,row.targetFarmId
  for k in pairs(row) do if k~="sourceFarmId" and k~="targetFarmId" then return nil end end
  if type(n)~="number" or n%1~=0 or n<=last or n>8 or reserved[n] or n==target or v~=target then return nil end
  out[n]=v;last=n
 end
 return out
end
local function row(a,b)return {sourceFarmId=a,targetFarmId=b} end
local rm=receiptMap({row(2,1),row(3,1)},1)
T.eq("persisted sequence permits source two",rm[2],1)
T.eq("persisted sequence permits same target for source three",rm[3],1)
T.eq("duplicate semantic source rows refuse before map construction",receiptMap({row(2,1),row(2,1)},1),nil)
T.eq("conflicting duplicate semantic source refuses",receiptMap({row(2,3),row(2,1)},1),nil)
T.eq("fractional source ID refuses",receiptMap({row(2.5,1)},1),nil)
T.eq("string source ID refuses",receiptMap({row("2",1)},1),nil)
T.eq("reserved source ID refuses",receiptMap({row(14,1)},1),nil)
T.eq("survivor as source refuses",receiptMap({row(1,1)},1),nil)
T.eq("incompatible target refuses",receiptMap({row(2,3)},1),nil)
T.eq("sequence hole refuses",receiptMap({[1]=row(2,1),[3]=row(3,1)},1),nil)
T.eq("non-sequence key refuses",receiptMap({row(2,1),other=row(3,1)},1),nil)
T.eq("source ordering is canonical",receiptMap({row(3,1),row(2,1)},1),nil)
T.eq("native MAX_FARM_ID is not stream capacity",receiptMap({row(9,1)},1),nil)
T.eq("native maximum valid source remains usable",receiptMap({row(8,1)},1)[8],1)
-- Model the generic decoder's result[key]=value semantics. Numeric sequence
-- positions retain two semantic source rows; keyed maps collapse them.
local function decodedEntries(entries)
 local t={};for _,e in ipairs(entries) do t[e[1]]=cp(e[2]) end;return t
end
local collapsed=decodedEntries({{"2",3},{"2",1}})
T.eq("control generic keyed decoder hides previous value",collapsed["2"],1)
local rows=decodedEntries({{1,row(2,1)},{2,row(2,1)}})
T.eq("sequence keeps both logical source entries",#rows,2)
T.eq("duplicate remains visible after generic decoder",receiptMap(rows,1),nil)
local s={receipts={R={map={row(2,1),row(3,1)},sourceSnapshot="N0"}},pending={A={receiptId="R",revision=4,generation=7,source="N0",current="N0",continuityLost=false},B={receiptId="R",revision=5,generation=9,source="N0",current="N0",continuityLost=false}},data={A={owner=2,stockId="stockA"},B={owner=3,stockId="stockB"}}}
local function bridge(s,key,from,to,gen,unchanged)
 local p=s.pending[key];if not p or p.continuityLost then return false end
 if not unchanged or p.current~=from or p.generation~=gen then p.continuityLost=true;return false end
 p.current=to;return true
end
T.eq("unchanged unit advances save association",bridge(s,"A","N0","N1",7,true),true)
T.eq("source proof stays original",s.pending.A.source,"N0")
local reload=cp(s)
T.eq("receipt survives serialization-style copy",reload.receipts.R.map[1].targetFarmId,1)
T.eq("current association survives reload",reload.pending.A.current,"N1")
local function commit(s,key,rev,native,gen,ok)
 local p=s.pending[key]
 if not p or p.continuityLost or p.revision~=rev or p.current~=native or p.generation~=gen or not ok then return false end
 local r=s.receipts[p.receiptId];if not r then return false end
 local decoded=receiptMap(r.map,1);if not decoded then return false end
 local candidate=cp(s.data[key]);local target=decoded[candidate.owner];if not target then return false end
 candidate.owner=target;s.data[key]=candidate;s.pending[key]=nil
 local retained=false;for _,o in pairs(s.pending) do if o.receiptId==p.receiptId then retained=true end end
 if not retained then s.receipts[p.receiptId]=nil end
 return true
end
T.eq("failed install leaves receipt",commit(reload,"A",4,"N1",7,false),false)
T.eq("failed install keeps original owner",reload.data.A.owner,2)
T.eq("failed install keeps pending marker",reload.pending.A.receiptId,"R")
T.eq("new unit cannot borrow old-farm proof",commit(reload,"newFarm2Unit",4,"N1",7,true),false)
T.eq("changed generation rejects old facts",commit(reload,"A",4,"N1",8,true),false)
T.eq("exact pending unit finishes later",commit(reload,"A",4,"N1",7,true),true)
T.eq("accepted current owner becomes survivor",reload.data.A.owner,1)
T.eq("stock identity remains",reload.data.A.stockId,"stockA")
T.eq("pending removed only with installation",reload.pending.A,nil)
T.ok("receipt retained while another source unit is pending",reload.receipts.R~=nil)
T.eq("second farm unit restores without target collision",commit(reload,"B",5,"N0",9,true),true)
T.eq("second farm stock remains distinct",reload.data.B.stockId,"stockB")
T.eq("second farm gets same surviving owner",reload.data.B.owner,1)
T.eq("unused receipt is collected",reload.receipts.R,nil)
T.eq("applied unit cannot transform again",commit(reload,"A",4,"N1",7,true),false)
local changed=cp(s)
T.eq("live turnover loses continuity",bridge(changed,"A","N1","N2",7,false),false)
T.eq("receipt is not content proof",commit(changed,"A",4,"N1",7,true),false)
T.eq("later equal values cannot clear lost continuity",bridge(changed,"A","N1","N2",7,true),false)

-- Native-field adapter model only. Exact class admission stands for captured
-- native registry/factory identity. This does not execute native hooks/setters.
local function normalize(child,ctx)
 if not ctx.server or ctx.loaded or ctx.mp or ctx.phase~="MERGED" or not ctx.mapAgrees then return false end
 if not child.admitted then return false end
 local t,k
 if child.class=="Vehicle" then t=child.palletAttributes;k="ownerFarmId"
 elseif child.class=="Bale" or child.class=="PackedBale" then
  if child.baleObject then t=child.baleObject;k="owner" else t=child.baleAttributes;k="farmId" end
 else return false end
 if not t or type(t[k])~="number" then return false end
 local target=ctx.map[t[k]]
 if target then t[k]=target;child.ownerWrites=(child.ownerWrites or 0)+1 end
 return true
end
local nc={server=true,loaded=false,mp=false,phase="MERGED",mapAgrees=true,map=m}
local pallet={admitted=true,class="Vehicle",palletAttributes={ownerFarmId=2,fillLevel=475,fillType="seed",uniqueId="P"}}
T.eq("native pallet conversion admitted",normalize(pallet,nc),true)
T.eq("stored pallet owner matches survivor",pallet.palletAttributes.ownerFarmId,1)
T.eq("native pallet amount preserved",pallet.palletAttributes.fillLevel,475)
T.eq("native pallet material preserved",pallet.palletAttributes.fillType,"seed")
T.eq("native pallet identity preserved",pallet.palletAttributes.uniqueId,"P")
normalize(pallet,nc);T.eq("repeated native pass changes owner once",pallet.ownerWrites,1)
local bale={admitted=true,class="Bale",baleAttributes={farmId=3,fillLevel=650,fermenting=false}}
normalize(bale,nc);T.eq("attribute-backed bale owner converts",bale.baleAttributes.farmId,1)
T.eq("attribute-backed bale amount unchanged",bale.baleAttributes.fillLevel,650)
local packed={admitted=true,class="PackedBale",baleAttributes={farmId=2,fillLevel=2400}}
normalize(packed,nc);T.eq("packed bale owner converts",packed.baleAttributes.farmId,1)
local hidden={admitted=true,class="Bale",baleObject={owner=2,fillLevel=4000,fermentation=.35}}
normalize(hidden,nc);T.eq("hidden live bale owner converts",hidden.baleObject.owner,1)
T.eq("hidden fermentation progress unchanged",hidden.baleObject.fermentation,.35)
local foreign={admitted=false,class="Vehicle",palletAttributes={ownerFarmId=2}}
T.eq("familiar foreign fields are not admission",normalize(foreign,nc),false)
T.eq("foreign owner untouched",foreign.palletAttributes.ownerFarmId,2)
local missing={admitted=true,class="Vehicle",palletAttributes={}}
T.eq("missing owner not guessed",normalize(missing,nc),false)
local ready=cp(nc);ready.loaded=true
T.eq("ordinary play does not rerun native restore repair",normalize(cp(bale),ready),false)
local mp=cp(nc);mp.mp=true
T.eq("multiplayer never uses SP correction",normalize(cp(bale),mp),false)
local bad=cp(nc);bad.mapAgrees=false
T.eq("native context disagreement refuses correction",normalize(cp(bale),bad),false)
local function canPublish(savedOwner,actualOwner,map)
 return actualOwner~=nil and actualOwner==(map[savedOwner] or savedOwner)
end
T.eq("root owner alone does not authorize old-owner child",canPublish(2,2,m),false)
T.eq("corrected actual child owner permits matched metadata",canPublish(2,1,m),true)
T.eq("retrieved native world object rechecked",canPublish(3,3,m),false)
