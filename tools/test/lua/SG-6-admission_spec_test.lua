-- SG-6: native material capacity admission contract (StockGuard core).
--!load: src/capacity/SGSha256.lua, src/capacity/SGCanonicalProfile.lua, src/capacity/SGWireFormats.lua, src/capacity/SGCapacity.lua
-- Part 1 is the delivered reference bar (Office Tyson/StockGuard-First-Family-
-- 2026-09-15/reference-tests/SG-6-admission_spec_test.lua) kept as shipped minus
-- its trailing summary call. Part 2 (appended below) drives the built core.

-- SG-6 v2: discriminating pure admission/framing reference, NOT native or production code.
-- Native source shapes: FillTypeManager.addFillType; Storage local supported lists;
-- SellingStation/ProductionPoint separate UInt8 material counts; map type/height ranges.
local function integer(n) return type(n)=="number" and n==math.floor(n) end
local function fits(n,b) return integer(n) and n>=0 and n<2^b end
local function admit(count,width,loading)
 if not loading then return nil,"FROZEN" end
 if not integer(count) or count<0 or not integer(width) or width<8 or width>15 then return nil,"INVALID" end
 local b=width
 while count+1>=2^b and b<15 do b=b+1 end
 if count+1>=2^b then return nil,"CAPACITY" end
 return b,"ADMITTED"
end
local function profile(width,names,ground,format)
 if not integer(width) or width<8 or width>15 or #names>2^width-1 then return nil end
 local out={tostring(width),tostring(#names),ground,format};local seen={}
 for _,n in ipairs(names) do
  if type(n)~="string" or n=="" or seen[n] then return nil end
  seen[n]=true;out[#out+1]=tostring(#n)..":"..n
 end
 return table.concat(out,"|") -- canonical identity witness, NOT SHA-256 implementation
end
local function join(state,expected,received)
 if not expected or expected~=received then state.closed=true;return false end
 state.promoted=true;state.sent=true;return true
end
local function groundFits(tf,tb,hf,hb,count)
 return integer(count) and count>=0 and count<2^tb and not (hf<tf+tb and tf<hf+hb)
end
local function applyFrame(entries,count,supported,width,state)
 if not fits(count,16) or count>32767 or count~=#entries or count~=#supported then return false end
 local prev=0
 for i,e in ipairs(entries) do
  if not integer(e.id) or e.id<=prev or not fits(e.id,width) or e.id~=supported[i] then return false end
  if e.present and (type(e.level)~="number" or e.level~=e.level or e.level==math.huge or e.level<0) then return false end
  prev=e.id
 end
 for _,e in ipairs(entries) do state.calls=state.calls+1;state[e.id]=e.present and e.level or 0 end
 return true
end
T.eq("native sample stays eight bits",admit(239,8,true),8)
T.eq("index255 still fits eight bits",admit(254,8,true),8)
T.eq("index256 grows before registration",admit(255,8,true),9)
T.eq("Hiller with Depot fits nine bits",admit(428,8,true),9)
T.eq("Montana with Depot fits nine bits",admit(470,8,true),9)
T.eq("deferred addition crosses511",admit(511,9,true),10)
T.eq("existing larger selected width retained",admit(470,12,true),12)
T.eq("late registration is refused",admit(240,8,false),nil)
T.eq("maximum supported registration fits",admit(32766,15,true),15)
T.eq("entry32768 refused without wrap",admit(32767,15,true),nil)
T.eq("noninteger width refused",admit(3,8.5,true),nil)
T.eq("unhandled larger width is not silently lowered",admit(3,16,true),nil)
T.eq("old UInt8 count cannot represent256",fits(256,8),false)
T.eq("paired UInt16 count represents256",fits(256,16),true)
T.eq("paired count represents spec bound",fits(32767,16),true)
T.eq("count65536 refused",fits(65536,16),false)
T.eq("production ordinal is not widened by material change",fits(256,8),false)
T.eq("shipped ground layout fits",groundFits(0,6,6,6,60),true)
T.eq("blind seventh type bit overlaps height",groundFits(0,7,6,6,60),false)
T.eq("authored seven plus seven layout fits",groundFits(0,7,7,7,120),true)
T.eq("six-bit ground count64 rejected",groundFits(0,6,6,6,64),false)
local a=profile(9,{"UNKNOWN","WHEAT","UREA"},"0,7,7,7","2,2")
local b=profile(9,{"UNKNOWN","UREA","WHEAT"},"0,7,7,7","2,2")
T.near("identity fixture width is independent of name count",9,9,0)
T.eq("same count different order is different identity",a==b,false)
T.eq("duplicate names refused",profile(9,{"WHEAT","WHEAT"},"0,6,6,6","2,2"),nil)
T.eq("width changes identity",a==profile(10,{"UNKNOWN","WHEAT","UREA"},"0,7,7,7","2,2"),false)
local js={sent=false,promoted=false,closed=false}
T.eq("mismatch refuses before object send",join(js,a,b),false)
T.eq("mismatch sent no objects",js.sent,false)
T.eq("mismatch promoted no player",js.promoted,false)
local good={sent=false,promoted=false,closed=false}
T.eq("matching profile proceeds",join(good,a,a),true)
T.eq("matching profile sends objects",good.sent,true)
local e={{id=1,present=true,level=5},{id=300,present=false}}
local state={calls=0}
T.eq("valid expanded storage list applies",applyFrame(e,2,{1,300},9,state),true)
T.eq("both validated entries applied",state.calls,2)
T.eq("absent native level becomes zero",state[300],0)
local bad={calls=0}
T.eq("same count different supported IDs refused",applyFrame(e,2,{1,301},9,bad),false)
T.eq("mismatch applies no partial level",bad.calls,0)
T.eq("short frame refused",applyFrame(e,3,{1,300},9,bad),false)
T.eq("old narrower ID width refuses300",applyFrame(e,2,{1,300},8,bad),false)
T.eq("negative native level refused",applyFrame({{id=1,present=true,level=-1}},1,{1},9,bad),false)
T.eq("malformed frames still no setter",bad.calls,0)

-- R1 fold discriminators: canonical byte grammar, wrappers and initialized-ground snapshots.
local function scalar(x)
 local v=type(x)=="boolean" and (x and "1" or "0") or tostring(x)
 return tostring(#v)..":"..v
end
local function canonical(p)
 local seq={"SG6_CAPACITY_2",2,p.width,#p.names,p.map,0,7,7,7,"MATERIAL_COUNTS_2","STORAGE_2",p.flags,p.maximum,#p.names}
 for i,n in ipairs(p.names) do seq[#seq+1]=i;seq[#seq+1]=n end
 seq[#seq+1]=#p.ground
 for _,g in ipairs(p.ground) do seq[#seq+1]=g.index;seq[#seq+1]=g.name;seq[#seq+1]=g.canTip and 1 or 0 end
 local out={};for _,v in ipairs(seq) do out[#out+1]=scalar(v) end
 return table.concat(out)
end
local cp={width=9,names={"UNKNOWN","WHEAT"},map="M",flags=0,maximum=32767,ground={}}
local expected="14:SG6_CAPACITY_21:21:91:21:M1:01:71:71:717:MATERIAL_COUNTS_29:STORAGE_21:05:327671:21:17:UNKNOWN1:25:WHEAT1:0"
T.eq("canonical schema has exact byte order and no separators",canonical(cp),expected)
T.eq("UTF8 length is bytes",scalar(string.char(195,137)),"2:"..string.char(195,137))
cp.flags=1;T.eq("integration flag changes canonical bytes",canonical(cp)==expected,false);cp.flags=0
cp.map="m";T.eq("native mapId case preserved",canonical(cp)==expected,false);cp.map="M"
cp.ground={{index=1,name="WHEAT",canTip=false}}
T.eq("ground pairs encode explicit index name and raw boolean",canonical(cp):sub(-16),"1:11:15:WHEAT1:0")
local function savedMatches(saved,current,existingRaster)
 if existingRaster and not saved then return false end
 local used={}
 for name,index in pairs(saved or {}) do
  if used[index] or current[name]~=index then return false end
  used[index]=true
 end
 return true
end
T.eq("saved same indices plus appended new material accepted",savedMatches({WHEAT=1},{WHEAT=1,UREA=2},true),true)
T.eq("saved equal names reordered refused",savedMatches({WHEAT=1,UREA=2},{WHEAT=2,UREA=1},true),false)
T.eq("saved missing material refused",savedMatches({WHEAT=1},{UREA=1},true),false)
T.eq("missing mapping is not empty heap proof",savedMatches(nil,{WHEAT=1},true),false)
T.eq("new no-raster save allowed",savedMatches(nil,{WHEAT=1},false),true)
local initialized={WHEAT=1};local live={WHEAT=1,UREA=2}
local function sameMap(a,b)
 for k,v in pairs(a) do if b[k]~=v then return false end end
 for k,v in pairs(b) do if a[k]~=v then return false end end
 return true
end
T.eq("late Lua insertion fails association signature",sameMap(initialized,live),false)
initialized.UREA=2;T.eq("prepared roster included in native pass stays equal",sameMap(initialized,live),true)
local w=9;local called=0
local function extender() w=12;called=called+1;return false end
local function frozenOuter(delegate) return function() return false,"FROZEN" end end
local guarded=frozenOuter(extender)
T.eq("outer ready guard refuses before selected extender",guarded(),false)
T.eq("refused late call kept frozen width",w,9)
T.eq("refused late call did not invoke delegate",called,0)
extender();T.eq("control: outside extender changes width before inner refusal",w,12)
T.eq("realSilo accepts high field width with representable actual IDs",fits(1000,14) and fits(1000,15),true)
T.eq("realSilo actual index16384 cannot be admitted",fits(16384,14),false)
T.eq("new static refusal code fits existing four-bit answer",fits(8,4),true)
local trace={}
local function parent() trace[#trace+1]="wideParent" end
local function pc() trace[#trace+1]="existingPCTail" end
local function dlc() trace[#trace+1]="wideDLCTail" end
parent();pc();dlc()
T.eq("named parent tail subclass order is preserved exactly once",table.concat(trace,","),"wideParent,existingPCTail,wideDLCTail")

-- R2 fold discriminators: saved-key normalization, append order, reused-host reset,
-- conditional failure completion, and transactional DLC dirty-list staging.
local function savedMatchesNativeKeys(saved,current,existingRaster)
 if existingRaster and not saved then return false end
 local used={}
 for name,index in pairs(saved or {}) do
  local key=string.lower(name)
  local expected;for canonical,position in pairs(current) do
   if string.lower(canonical)==key then expected=position end
  end
  if used[index] or expected~=index then return false end
  used[index]=true
 end
 return true
end
T.eq("saved lowercase key matches canonical uppercase name",savedMatchesNativeKeys({wheat=1},{WHEAT=1},true),true)
T.eq("saved changed index still refuses after lowercase lookup",savedMatchesNativeKeys({wheat=2},{WHEAT=1},true),false)

local function prepareGroundRoster(existing,missing)
 local out={};local seen={};for _,n in ipairs(existing) do out[#out+1]=n;seen[n.name]=true end
 table.sort(out,function(a,b)return a.fillIndex<b.fillIndex end)
 for _,n in ipairs(missing) do if not seen[n.name] then out[#out+1]=n;seen[n.name]=true end end
 return out
end
local roster=prepareGroundRoster({{name="ZINC",fillIndex=400},{name="WHEAT",fillIndex=100}},{{name="POLIFOSKA",fillIndex=350}})
T.eq("existing ground roster sorts by native fill index before Soil append",roster[1].name..","..roster[2].name..","..roster[3].name,"WHEAT,ZINC,POLIFOSKA")
T.eq("old Soil appended index survives canonical name comparison",savedMatchesNativeKeys({wheat=1,zinc=2,polifoska=3},{WHEAT=1,ZINC=2,POLIFOSKA=3},true),true)
local again=prepareGroundRoster({},{});for i,v in ipairs(roster) do again[i]=v end
table.sort(again,function(a,b)return a.fillIndex<b.fillIndex end)
T.eq("final native index sort would move appended Soil below ZINC",again[2].name,"POLIFOSKA")
T.eq("missing-only append skips an existing XML definition",#prepareGroundRoster({{name="WHEAT",fillIndex=100}},{{name="WHEAT",fillIndex=100}}),1)

local reused={width=12,externalFloor=12,ownGrowth=nil,phase="READY",guardReady=true}
local function growForDemand(s,bits) s.ownGrowth=bits;s.width=bits end
local function unloadEpoch(s)
 if s.ownGrowth~=nil and s.width==s.ownGrowth then s.width=s.externalFloor end
 s.ownGrowth=nil;s.phase="LOADING";s.guardReady=false
end
growForDemand(reused,15);unloadEpoch(reused)
T.eq("reused host unload removes SG6 demand growth",reused.width,12)
T.eq("known external twelve-bit floor survives unload",reused.externalFloor,12)
T.eq("reused host reopens LOADING before UNKNOWN registration",reused.phase..":"..tostring(reused.guardReady),"LOADING:false")
T.eq("reused host and fresh client share selected startup floor",reused.width,12)

local function conditionalFinish(s)
 if s.failed then if not s.presented then s.presented=true;s.completions=s.completions+1 end;return false end
 s.original=s.original+1;return true
end
local failedFinish={failed=true,completions=0,original=0}
T.eq("FAILED completion suppresses original finished-loading body",conditionalFinish(failedFinish),false)
T.eq("FAILED completion does not call original",failedFinish.original,0)
conditionalFinish(failedFinish)
T.eq("repeated FAILED completion presents only once",failedFinish.completions,1)
local goodFinish={failed=false,completions=0,original=0}
T.eq("valid completion calls native body",conditionalFinish(goodFinish),true)
T.eq("valid completion calls native body once",goodFinish.original,1)

local function validRows(rows)
 if #rows>32767 then return false end
 for _,r in ipairs(rows) do if not integer(r.id) or r.id<1 or r.id>32767 then return false end end
 return true
end
local function applyDlcDirtyFrame(s,inDirty,ins,outDirty,outs)
 if (inDirty and not validRows(ins)) or (outDirty and not validRows(outs)) then return false end
 if inDirty then s.inputs=ins end
 if outDirty then s.outputs=outs end
 return true
end
local dlc={inputs={{id=1}},outputs={{id=2}},inputDirty=false,outputDirty=false}
local manyIn={};for i=1,256 do manyIn[i]={id=i} end
local manyOut={};for i=1,300 do manyOut[i]={id=i} end
T.eq("DLC dirty input count beyond127 stages",applyDlcDirtyFrame(dlc,true,manyIn,false,{}),true)
T.eq("DLC dirty output count beyond255 stages",applyDlcDirtyFrame(dlc,false,{},true,manyOut),true)
local beforeIn, beforeOut=dlc.inputs,dlc.outputs
local differentIn={{id=12}}
local invalidOut={{id=1},{id=0}}
T.eq("invalid later DLC list rejects entire frame",applyDlcDirtyFrame(dlc,true,differentIn,true,invalidOut),false)
T.eq("invalid later list applies no earlier input mutation",dlc.inputs,beforeIn)
T.eq("invalid later list applies no output mutation",dlc.outputs,beforeOut)
T.eq("false dirty branch remains untouched",applyDlcDirtyFrame(dlc,false,invalidOut,false,invalidOut),true)
T.eq("false dirty branch keeps input reference",dlc.inputs,beforeIn)

-- R3 fold discriminators: preflight and Soil join ordering, standalone tip gates,
-- unload delegation, and mission-scoped floor-writer identity.
local function soilPreflight(selected,api,delegate)
 if selected and (type(api)~="table" or api.protocolVersion~=2 or type(api.beginCapacityLoad)~="function" or type(api.prepareGroundTypes)~="function" or type(api.endCapacityLoad)~="function") then return false,"SOIL_API" end
 delegate.calls=delegate.calls+1;return true,"OK"
end
local oldSoilDelegate={calls=0}
T.eq("selected old Soil is blocked before Mission00 delegate",soilPreflight(true,nil,oldSoilDelegate),false)
T.eq("old Soil preflight made no delegate call",oldSoilDelegate.calls,0)
local soilProtocol={protocolVersion=2,beginCapacityLoad=function() end,prepareGroundTypes=function() end,endCapacityLoad=function() end}
local validSoilDelegate={calls=0}
T.eq("selected Soil with capacity API proceeds",soilPreflight(true,soilProtocol,validSoilDelegate),true)
T.eq("valid Soil preflight reaches delegate once",validSoilDelegate.calls,1)
local incompleteSoil={beginCapacityLoad=function() end,prepareGroundTypes=function() end}
T.eq("Soil API missing completion method is blocked",soilPreflight(true,incompleteSoil,{calls=0}),false)
T.eq("Soil absence remains supported",soilPreflight(false,nil,{calls=0}),true)

local function beginCapacityLoad(s,prepOk,fillOk)
 s.joined=true -- must precede either preparation result and legacy callbacks
 if not prepOk or not fillOk then s.failed=true;return false end
 s.prepared=true;return true
end
local joinedFail={joined=false,legacyCalls=0}
T.eq("failed joined preparation is reported as failure",beginCapacityLoad(joinedFail,false,true),false)
T.eq("failed preparation disables legacy ground insertion",joinedFail.joined and joinedFail.legacyCalls,0)
local function legacyGroundInsert(s)
 if s.joined then return false end
 s.legacyCalls=s.legacyCalls+1;return true
end
T.eq("legacy insertion stays disabled after preparation failure",legacyGroundInsert(joinedFail),false)
local fillFail={joined=false,legacyCalls=0}
T.eq("fill failure before ground preparation still joins Soil",beginCapacityLoad(fillFail,true,false),false)
T.eq("fill failure before ground preparation disables legacy insertion",legacyGroundInsert(fillFail),false)

local function standaloneTip(s,managerValid,nativeCanTip)
 if managerValid and s.active and not s.joined and s.registered then s.legacyCalls=s.legacyCalls+1;return true end
 return nativeCanTip
end
local standalone={active=true,joined=false,registered=true,legacyCalls=0}
T.eq("control: active legacy wrapper overrides native false",standaloneTip(standalone,true,false),true)
beginCapacityLoad(standalone,true,true)
T.eq("joined mission disables surviving standalone tip wrapper",standaloneTip(standalone,true,false),false)
T.eq("disabled Soil wrapper preserves an earlier outside predecessor result",standaloneTip(standalone,true,true),true)
standalone.active=false;standalone.joined=false
T.eq("unload disables surviving standalone tip wrapper",standaloneTip(standalone,true,false),false)
local invalidManager={active=true,joined=false,legacyCalls=0}
T.eq("invalid manager falls through original native result",standaloneTip(invalidManager,false,false),false)
T.eq("invalid manager does not call stale legacy body",invalidManager.legacyCalls,0)

local function unloadWithDelegate(s,delegate)
 s.phase="LOADING";s.joined=false;s.profile=nil;s.active=false
 delegate.calls=delegate.calls+1;return true
end
local unloadDelegate={calls=0};local reusedR3={phase="READY",joined=true,profile="old"}
T.eq("unload reset invokes captured native delegate once",unloadWithDelegate(reusedR3,unloadDelegate),true)
T.eq("unload delegate count is exactly one",unloadDelegate.calls,1)
T.eq("unload clears joined profile state and reopens loading",reusedR3.phase..":"..tostring(reusedR3.joined)..":"..tostring(reusedR3.profile),"LOADING:false:nil")

local function missionFloors(mods)
 local floors={};for _,id in ipairs(mods) do
  if id=="fixed9" then floors[id]=9 elseif id=="redux10" then floors[id]=10
  elseif id=="UFT12" then floors[id]=12 end
 end
 return floors
end
local floorsA=missionFloors({"fixed9","redux10","UFT12"});local floorsB=missionFloors({"fixed9","redux10","UFT12"})
T.eq("same width does not infer unselected UFT writer",missionFloors({"fixed9","redux10"}).UFT12,nil)
T.eq("mission mod list admits selected UFT writer",floorsB.UFT12,12)
local function writerIdentity(f)
 local ids={};for id in pairs(f) do ids[#ids+1]=id end;table.sort(ids);return table.concat(ids,",")
end
T.eq("same writer set keeps stable identity at same width",writerIdentity(floorsA)==writerIdentity(missionFloors({"fixed9","redux10","UFT12"})),true)
T.eq("alternate twelve-bit writer set has distinct identity",writerIdentity(floorsA)==writerIdentity(missionFloors({"UFT12"})),false)


-- =====================================================================
-- PART 2: the built SG-6 core (Fred, 2026-09-15)
-- =====================================================================

-- Engine surface the core touches, stubbed for the bench.
function streamWriteUInt16(s, v) streamWriteInt32(s, v) end
function streamReadUInt16(s) return streamReadInt32(s) end
function streamWriteUIntN(s, v, n) streamWriteInt32(s, v) end
function streamReadUIntN(s, n) return streamReadInt32(s) end
Utils = Utils or {}
function Utils.overwrittenFunction(oldFunc, newFunc)
    if oldFunc == nil then return function(self, ...) return newFunc(self, nil, ...) end end
    return function(self, ...) return newFunc(self, oldFunc, ...) end
end
function Utils.appendedFunction(oldFunc, newFunc)
    if oldFunc == nil then return newFunc end
    return function(...) oldFunc(...) newFunc(...) end
end
bit32 = bit32 or { band = function(a, b) local r, bit = 0, 1 for _ = 1, 32 do if a % 2 == 1 and b % 2 == 1 then r = r + bit end a = math.floor(a / 2) b = math.floor(b / 2) bit = bit * 2 end return r end }
g_i18n = { getText = function(_, k) return k end }

local SHA, CP, WF, CAP = SGSha256, SGCanonicalProfile, SGWireFormats, SGCapacity

-- (A) SHA-256 standard vectors.
do
    local _, e = SHA.digest("")
    T.eq("A1 sha256 empty", e, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    local o, a = SHA.digest("abc")
    T.eq("A2 sha256 abc", a, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    T.eq("A3 32 octets", #o, 32)
    T.eq("A4 first octet", o[1], 0xba)
    local _, two = SHA.digest("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")
    T.eq("A5 sha256 two-block vector", two, "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    local _, long = SHA.digest(string.rep("a", 1000))
    T.eq("A6 sha256 1000 x a", long, "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
end

-- (B) Canonical bytes: the exact grammar the bar specifies.
do
    local p = { widthBits = 9, mapId = "M", typeFirstChannel = 0, typeNumChannels = 7, heightFirstChannel = 7, heightNumChannels = 7,
        integrationFlags = 0, effectiveMaximumNativeIndex = 32767, names = { "UNKNOWN", "WHEAT" }, ground = {} }
    local expected = "14:SG6_CAPACITY_21:21:91:21:M1:01:71:71:717:MATERIAL_COUNTS_29:STORAGE_21:05:327671:21:17:UNKNOWN1:25:WHEAT1:0"
    T.eq("B1 canonical bytes match the bar's exact expected sequence", (CP.canonicalBytes(p)), expected)
    p.integrationFlags = 1
    T.ok("B2 integration flag changes the bytes", CP.canonicalBytes(p) ~= expected)
    p.integrationFlags = 0
    p.mapId = "m"
    T.ok("B3 mapId case preserved", CP.canonicalBytes(p) ~= expected)
    p.mapId = "M"
    p.ground = { { index = 1, name = "WHEAT", canBeTipped = false } }
    T.eq("B4 ground pair encodes index, name and raw boolean", CP.canonicalBytes(p):sub(-16), "1:11:15:WHEAT1:0")
    T.eq("B5 UTF-8 length is bytes", CP.scalar(string.char(195, 137)), "2:" .. string.char(195, 137))
    p.ground = {}
    p.names = { "WHEAT", "WHEAT" }
    T.eq("B6 duplicate names refused", (CP.canonicalBytes(p)), nil)
    p.names = { "UNKNOWN", "WHEAT" }
    p.integrationFlags = 16
    T.eq("B7 unknown integration bit refused", select(2, CP.canonicalBytes(p)), "UNKNOWN_INTEGRATION_FLAG")
    p.integrationFlags = 0
    p.ground = { { index = 2, name = "A", canBeTipped = true }, { index = 1, name = "B", canBeTipped = true } }
    T.eq("B8 unordered ground indices refused", select(2, CP.canonicalBytes(p)), "INVALID_GROUND")
    p.ground = {}
    local prof = CP.build(p, 3)
    T.eq("B9 profile digest is 64 hex chars", #prof.digestHex, 64)
    T.eq("B10 profile registeredCount", prof.registeredCount, 2)
    T.eq("B11 reserved format flag refused", select(2, CP.build(p, 4)), "INVALID_FORMAT_FLAGS")
    -- Width changes identity; different order changes identity.
    local a = CP.build(p, 3)
    p.widthBits = 10
    local b = CP.build(p, 3)
    T.ok("B12 width changes the digest", a.digestHex ~= b.digestHex)
    p.widthBits = 9
    p.names = { "UNKNOWN", "UREA", "WHEAT" }
    local c = CP.build(p, 3)
    p.names = { "UNKNOWN", "WHEAT", "UREA" }
    local d = CP.build(p, 3)
    T.ok("B13 same names in another order is a different identity", c.digestHex ~= d.digestHex)
end

-- (C) Header codec and comparison.
do
    local p = { widthBits = 9, mapId = "M", typeFirstChannel = 0, typeNumChannels = 7, heightFirstChannel = 7, heightNumChannels = 7,
        integrationFlags = 8, effectiveMaximumNativeIndex = 32767, names = { "UNKNOWN", "WHEAT" }, ground = { { index = 1, name = "WHEAT", canBeTipped = true } } }
    local prof = CP.build(p, 3)
    local h = { magic = CP.HEADER_MAGIC, version = prof.version, widthBits = prof.widthBits, registeredCount = prof.registeredCount, formatFlags = prof.formatFlags, digest = prof.digest }
    local s = NewStream()
    CP.writeHeader(s, h)
    T.eq("C1 header is 4 + 1 + 1 + 2 + 1 + 32 fields", s.w, 37)
    local back = CP.readHeader(s)
    T.eq("C2 magic round-trips", back.magic, 0x53473632)
    T.ok("C3 header equal after round trip", (CP.compare(h, back)))
    back.widthBits = 10
    T.eq("C4 width mismatch named", select(2, CP.compare(h, back)), "width")
    back.widthBits = 9
    back.digest[32] = (back.digest[32] + 1) % 256
    T.eq("C5 digest mismatch named", select(2, CP.compare(h, back)), "digest")
    back.digest[32] = h.digest[32]
    back.formatFlags = 1
    T.eq("C6 format flag mismatch named", select(2, CP.compare(h, back)), "formatFlags")
    back.formatFlags = 3
    T.eq("C7 well-formed header accepted", CP.headerIsWellFormed(back), true)
    back.formatFlags = 4
    T.eq("C8 reserved format flag refused", CP.headerIsWellFormed(back), false)
    back.formatFlags = 3
    back.version = 1
    T.eq("C9 wrong profile version refused", CP.headerIsWellFormed(back), false)
end

-- (D) Sizing: the smallest width for the next index, floors and bounds.
do
    T.eq("D1 requiredWidth 240", CAP.requiredWidth(240), 8)
    T.eq("D2 requiredWidth 255", CAP.requiredWidth(255), 8)
    T.eq("D3 requiredWidth 256", CAP.requiredWidth(256), 9)
    T.eq("D4 requiredWidth 512", CAP.requiredWidth(512), 10)
    T.eq("D5 requiredWidth 32767", CAP.requiredWidth(32767), 15)
    local c = CAP.new()
    T.eq("D6 native sample stays eight bits", (c:sizeFor(240, 8)), 8)
    T.eq("D7 index 256 grows to nine before registration", (c:sizeFor(256, 8)), 9)
    T.eq("D8 existing larger selected width retained", (c:sizeFor(471, 12)), 12)
    T.eq("D9 deferred addition crosses 511", (c:sizeFor(512, 9)), 10)
    T.eq("D10 maximum supported registration fits", (c:sizeFor(32767, 15)), 15)
    T.eq("D11 entry 32768 refused without wrap", select(2, c:sizeFor(32768, 15)), "CAPACITY")
    c.externalStartupFloor = 12
    T.eq("D12 external floor honoured", (c:sizeFor(3, 8)), 12)
    c.consumerBound = 16383
    T.eq("D13 consumer bound refuses beyond 16383", select(2, c:sizeFor(16384, 15)), "CAPACITY")
    c.phase = CAP.PHASE_READY
    T.eq("D14 late registration is FROZEN", select(2, c:sizeFor(3, 8)), "FROZEN")
end

-- (E) Epoch reset and the external floor.
do
    local c = CAP.new()
    c:onMapDataEntry(12)
    T.eq("E1 external floor captured", c.externalStartupFloor, 12)
    c.widthBits = 15; c.ownGrowth = 15; c.phase = CAP.PHASE_READY
    local written
    c:onEpochReset(15, function(w) written = w end)
    T.eq("E2 reused host unload restores the external floor", written, 12)
    T.eq("E3 reopens LOADING", c.phase, CAP.PHASE_LOADING)
    T.eq("E4 own growth removed", c.ownGrowth, nil)
    T.eq("E5 floor survives unload", c.externalStartupFloor, 12)
    -- The native field changed outside the supported writers.
    c.widthBits = 12
    written = nil
    c:onEpochReset(13, function(w) written = w end)
    T.eq("E6 unexpected width change leaves the field untouched", written, nil)
    c:onMapDataEntry(13)
    T.eq("E7 next load is incompatible", c.phase, CAP.PHASE_FAILED)
    T.eq("E8 with the reason", c.reasonCode, "EXTERNAL_WIDTH_CHANGE")
end

-- (F) Preflight: unbound adapters refuse, Soil protocol negotiated, absence supported.
do
    local function mods(...) local t = {} for _, n in ipairs({ ... }) do t[#t + 1] = { modName = n } end return { mods = t } end
    local c = CAP.new()
    local ok, why, who = c:preflight({}, mods("FS25_ProductionControl"), function() return nil end)
    T.eq("F1 unbound ProductionControl refused", why, "UNBOUND_ADAPTER")
    T.eq("F2 offending package named", who, "FS25_ProductionControl")
    T.eq("F3 realSilo refused", select(2, CAP.new():preflight({}, mods("FS25_realSilo"), nil)), "UNBOUND_ADAPTER")
    T.eq("F4 UnlimitedFillTypes refused", select(2, CAP.new():preflight({}, mods("FS25_UnlimitedFillTypes"), nil)), "UNBOUND_ADAPTER")
    T.eq("F5 Pumps N Hoses pack refused", select(2, CAP.new():preflight({}, mods("pdlc_pumpsAndHosesPack"), nil)), "UNBOUND_ADAPTER")
    T.eq("F6 Soil selected without protocol refused", select(2, CAP.new():preflight({}, mods("FS25_SoilFertilizer"), function() return nil end)), "SOIL_PROTOCOL")
    local incomplete = { protocolVersion = 2, beginCapacityLoad = function() return true end, prepareGroundTypes = function() end }
    T.eq("F7 incomplete Soil API refused", select(2, CAP.new():preflight({}, mods("FS25_SoilFertilizer"), function() return incomplete end)), "SOIL_PROTOCOL")
    local refusing = { protocolVersion = 2, beginCapacityLoad = function() return false end, prepareGroundTypes = function() end, endCapacityLoad = function() end }
    T.eq("F8 Soil begin false refused", select(2, CAP.new():preflight({}, mods("FS25_SoilFertilizer"), function() return refusing end)), "SOIL_BEGIN_REFUSED")
    local throwing = { protocolVersion = 2, beginCapacityLoad = function() error("x") end, prepareGroundTypes = function() end, endCapacityLoad = function() end }
    T.eq("F9 Soil begin throw refused", select(2, CAP.new():preflight({}, mods("FS25_SoilFertilizer"), function() return throwing end)), "SOIL_BEGIN_REFUSED")
    local began = {}
    local good = { protocolVersion = 2, beginCapacityLoad = function(m) began[#began + 1] = m return true end, prepareGroundTypes = function() return true end, endCapacityLoad = function() return true end }
    local c2 = CAP.new()
    local mission = { name = "m" }
    T.eq("F10 compatible Soil admitted", (c2:preflight(mission, mods("FS25_SoilFertilizer", "FS25_StateLedger"), function() return good end)), true)
    T.eq("F11 begin received the mission", began[1], mission)
    T.eq("F12 Soil join sets integration bit 3", c2.integrationFlags, 8)
    local c3 = CAP.new()
    T.eq("F13 absence of Soil is supported", (c3:preflight(mission, mods("FS25_StateLedger"), function() return nil end)), true)
    T.eq("F14 no Soil: no integration bits", c3.integrationFlags, 0)
end

-- (G) Ground preparation: sort first, Soil append, channel overlap, saved mapping.
do
    local function hm(rows, typeFirst, typeNum)
        local m = { heightTypeFirstChannel = typeFirst, heightTypeNumChannels = typeNum, heightTypes = {}, tipTypeMappings = nil, sorted = 0 }
        for i, r in ipairs(rows) do m.heightTypes[i] = { index = i, fillTypeName = r[1], fillTypeIndex = r[2], canBeTipped = r[3] ~= false } end
        m.sortHeightTypes = function(self)
            self.sorted = self.sorted + 1
            table.sort(self.heightTypes, function(a, b) return a.fillTypeIndex < b.fillTypeIndex end)
            for i, ht in ipairs(self.heightTypes) do ht.index = i end
        end
        return m
    end
    local channels = { typeFirst = 0, typeNum = 6, heightFirst = 6, heightNum = 6 }
    local c = CAP.new()
    local m = hm({ { "ZINC", 400 }, { "WHEAT", 100 } }, 0, 6)
    T.eq("G1 prepare ok", c:prepareGround(m, {}, channels, false), true)
    T.eq("G2 existing rows sorted by native fill index first", m.heightTypes[1].fillTypeName, "WHEAT")
    T.eq("G3 signature recorded", #c.groundSignature, 2)
    T.eq("G4 ground capacity 2^6-1", c.groundCapacity, 63)
    -- Soil join appends after the sort and receives the map limit.
    local c2 = CAP.new()
    local got
    c2.soilJoined = true
    c2.soilApi = { prepareGroundTypes = function(mgr, fm, limit) got = limit
        mgr.heightTypes[#mgr.heightTypes + 1] = { index = #mgr.heightTypes + 1, fillTypeName = "POLIFOSKA", fillTypeIndex = 350, canBeTipped = true } return true end }
    local m2 = hm({ { "ZINC", 400 }, { "WHEAT", 100 } }, 0, 7)
    T.eq("G5 joined prepare ok", c2:prepareGround(m2, {}, { typeFirst = 0, typeNum = 7, heightFirst = 7, heightNum = 7 }, false), true)
    T.eq("G6 Soil received the map limit", got, 127)
    T.eq("G7 appended row keeps its slot after the existing sorted rows (no final sort)", m2.heightTypes[3].fillTypeName, "POLIFOSKA")
    local c3 = CAP.new()
    c3.soilJoined = true
    c3.soilApi = { prepareGroundTypes = function() return false, "MISSING_NATIVE_FILL", "AN" end }
    T.eq("G8 Soil prepare false fails the load", c3:prepareGround(hm({ { "WHEAT", 100 } }, 0, 6), {}, channels, false), false)
    T.eq("G9 with the Soil reason", c3.reasonCode, "SOIL_PREPARE:MISSING_NATIVE_FILL")
    T.eq("G10 and the offending name", c3.offending, "AN")
    local c4 = CAP.new()
    T.eq("G11 blind seventh type bit overlapping height fails", c4:prepareGround(hm({ { "WHEAT", 100 } }, 0, 7), {}, { typeFirst = 0, typeNum = 7, heightFirst = 6, heightNum = 6 }, false), false)
    T.eq("G12 overlap reason", c4.reasonCode, "GROUND_CHANNEL_OVERLAP")
    local rows = {}
    for i = 1, 64 do rows[i] = { "T" .. i, i } end
    local c5 = CAP.new()
    T.eq("G13 six-bit ground count 64 refused", c5:prepareGround(hm(rows, 0, 6), {}, channels, false), false)
    -- Saved mapping: lowercase keys, same index; changed index refuses; missing mapping on an accepted save refuses.
    local c6 = CAP.new()
    local m6 = hm({ { "WHEAT", 100 }, { "ZINC", 400 } }, 0, 6)
    m6.tipTypeMappings = { wheat = 1, zinc = 2 }
    T.eq("G14 saved lowercase keys match canonical names", c6:prepareGround(m6, {}, channels, true), true)
    local c7 = CAP.new()
    local m7 = hm({ { "WHEAT", 100 }, { "ZINC", 400 } }, 0, 6)
    m7.tipTypeMappings = { wheat = 2, zinc = 1 }
    T.eq("G15 saved reordered names refused", c7:prepareGround(m7, {}, channels, true), false)
    T.eq("G16 reason", c7.reasonCode, "SAVED_MAPPING_CHANGED")
    local c8 = CAP.new()
    T.eq("G17 accepted save without a mapping refused", c8:prepareGround(hm({ { "WHEAT", 100 } }, 0, 6), {}, channels, true), false)
    T.eq("G18 reason", c8.reasonCode, "SAVED_MAPPING_MISSING")
    local c9 = CAP.new()
    local m9 = hm({ { "WHEAT", 100 }, { "ZINC", 400 }, { "POLIFOSKA", 350 } }, 0, 6)
    m9.tipTypeMappings = { wheat = 1 }
    T.eq("G19 new material appended without moving a saved pair is accepted", c9:prepareGround(m9, {}, channels, true), true)
end

-- (H) Freeze, state, availability and admission.
do
    local function fm(names) local t = { fillTypes = {} } for i, n in ipairs(names) do t.fillTypes[i] = { name = n, index = i } end return t end
    local function hmOf(sig) local m = { heightTypes = {} } for i, g in ipairs(sig) do m.heightTypes[i] = { index = g.index, fillTypeName = g.name, canBeTipped = g.canBeTipped } end return m end
    local channels = { typeFirst = 0, typeNum = 6, heightFirst = 6, heightNum = 6 }
    local c = CAP.new()
    c:onMapDataEntry(8)
    c.groundSignature = { { index = 1, name = "WHEAT", canBeTipped = true }, { index = 2, name = "UREA", canBeTipped = false } }
    c.groundTypeBits, c.groundCapacity = 6, 63
    c.widthBits = 9
    T.eq("H1 freeze READY", c:freeze(fm({ "UNKNOWN", "WHEAT", "UREA" }), hmOf(c.groundSignature), "map01", channels, 9), true)
    local st = c:getState()
    T.eq("H2 state phase", st.phase, "READY")
    T.eq("H3 state width", st.widthBits, 9)
    T.eq("H4 state registered", st.registeredCount, 3)
    T.eq("H5 state type capacity", st.typeCapacity, 511)
    T.eq("H6 state ground capacity", st.groundCapacity, 63)
    local av = c:getMaterialAvailability("UREA")
    T.eq("H7 availability native index", av.nativeIndex, 3)
    T.eq("H8 availability ground index", av.groundIndex, 2)
    T.eq("H9 availability raw canBeTipped", av.canBeTipped, false)
    T.eq("H10 unknown name explicit", c:getMaterialAvailability("GOLD").reasonCode, "UNKNOWN_NAME")
    local h = c:getHeader()
    T.eq("H11 header registeredCount", h.registeredCount, 3)
    T.eq("H12 same header admitted", (c:admit("conn-a", h)), true)
    local other = { magic = h.magic, version = h.version, widthBits = 10, registeredCount = h.registeredCount, formatFlags = h.formatFlags, digest = h.digest }
    local ok, comp = c:admit("conn-b", other)
    T.eq("H13 different width refused", ok, false)
    T.eq("H14 component named", comp, "width")
    T.eq("H15 malformed header refused", select(2, c:admit("conn-c", { version = 0, widthBits = 0, registeredCount = 0, formatFlags = 0, digest = {} })), "header")
    -- Width changed between initialize and freeze.
    local c2 = CAP.new()
    c2.widthBits = 9
    c2.groundSignature = {}
    T.eq("H16 width changed at freeze fails", c2:freeze(fm({ "UNKNOWN" }), hmOf({}), "map01", channels, 10), false)
    T.eq("H17 reason", c2.reasonCode, "WIDTH_CHANGED")
    -- Late Lua ground insertion after the initialize pass fails the freeze.
    local c3 = CAP.new()
    c3.widthBits = 8
    c3.groundSignature = { { index = 1, name = "WHEAT", canBeTipped = true } }
    T.eq("H18 ground changed after initialization fails", c3:freeze(fm({ "UNKNOWN", "WHEAT" }), hmOf({ { index = 1, name = "WHEAT", canBeTipped = true }, { index = 2, name = "UREA", canBeTipped = true } }), "map01", channels, 8), false)
    T.eq("H19 reason", c3.reasonCode, "GROUND_CHANGED")
    local c4 = CAP.new()
    c4.widthBits = 8
    T.eq("H20 no initialized ground fails the freeze", c4:freeze(fm({ "UNKNOWN" }), hmOf({}), "map01", channels, 8), false)
    T.eq("H21 a FAILED controller never freezes READY", c4:freeze(fm({ "UNKNOWN" }), hmOf({}), "map01", channels, 8), false)
end

-- (I) Installed hooks against engine stubs: sizing at registration, preflight
-- refusal without the delegate, initialize wrap, conditional finish, header
-- admission, answer 8.
do
    FillTypeManager = { SEND_NUM_BITS = 8 }
    function FillTypeManager:addFillType(desc)
        desc.index = #self.fillTypes + 1
        self.fillTypes[#self.fillTypes + 1] = desc
        return true
    end
    function FillTypeManager:loadMapData() return true end
    function FillTypeManager:unloadMapData() self.fillTypes = {} end
    local delegateCalls = 0
    Mission00 = { setMissionInfo = function(self, mi, mdi) delegateCalls = delegateCalls + 1 end, load = function() end }
    DensityMapHeightManager = { initialize = function(self) self.initialized = (self.initialized or 0) + 1 end }
    local finishedCalls = 0
    FSBaseMission = { onFinishedLoading = function(self) finishedCalls = finishedCalls + 1 return "native" end,
        onConnectionRequestAnswer = function(self, connection, answer) self.answered = answer end }
    BaseMissionFinishedLoadingEvent = { writeStream = function(self, s) streamWriteFloat32(s, self.posX) streamWriteFloat32(s, self.posY) streamWriteFloat32(s, self.posZ) streamWriteFloat32(s, self.viewDistanceCoeff) end,
        run = function(self, connection) self.ran = (self.ran or 0) + 1 end }
    ConnectionRequestAnswerEvent = { new = function(answer) return { answer = answer } end }
    local shown = {}
    InfoDialog = { INSTANCE = {}, show = function(text, cb) shown[#shown + 1] = text if cb then cb() end end }
    local quits = 0
    OnInGameMenuMenu = function() quits = quits + 1 end
    SellingStation, ProductionPoint, Storage = nil, nil, nil   -- wire install waits for the classes
    g_dedicatedServer = nil

    local ctl = CAP.new()
    CAP.installHooks(ctl)
    local ftm = setmetatable({ fillTypes = {} }, { __index = FillTypeManager })
    g_fillTypeManager = ftm
    ftm:loadMapData()
    T.eq("I1 map-data entry captured the native floor", ctl.externalStartupFloor, 8)
    for i = 1, 255 do ftm:addFillType({ name = "F" .. i }) end
    T.eq("I2 255 registrations stay at eight bits", FillTypeManager.SEND_NUM_BITS, 8)
    T.eq("I3 the 256th registration widens to nine before it lands", (ftm:addFillType({ name = "F256" })), true)
    T.eq("I4 native field is nine", FillTypeManager.SEND_NUM_BITS, 9)
    T.eq("I5 index 256 registered", ftm.fillTypes[256].name, "F256")

    -- Preflight refusal never reaches the delegate; one notice; repeated entry is quiet.
    local mission = { missionInfo = { mapId = "map01", isValid = false }, cancelLoading = false }
    g_currentMission = mission
    Mission00.setMissionInfo(mission, {}, { mods = { { modName = "FS25_realSilo" } } })
    T.eq("I6 unbound package: delegate not called", delegateCalls, 0)
    T.eq("I7 unbound package: cancelLoading set", mission.cancelLoading, true)
    T.eq("I8 unbound package: one notice", #shown, 1)
    T.ok("I9 notice names the package", shown[1]:find("FS25_realSilo", 1, true) ~= nil)
    T.eq("I10 notice tore down once", quits, 1)
    Mission00.setMissionInfo(mission, {}, { mods = { { modName = "FS25_realSilo" } } })
    T.eq("I11 repeated refused entry issues no second notice", #shown, 1)
    T.eq("I12 and still no delegate", delegateCalls, 0)
    -- Finished loading on the FAILED path: original suppressed, once.
    FSBaseMission.onFinishedLoading(mission)
    FSBaseMission.onFinishedLoading(mission)
    T.eq("I13 FAILED completion suppresses the native finished-loading body", finishedCalls, 0)
    T.eq("I14 no second notice on repeated completion", #shown, 1)

    -- A fresh epoch: unload, a compatible selection, ground, freeze READY.
    ftm:unloadMapData()
    T.eq("I15 unload reopened LOADING", ctl.phase, "LOADING")
    T.eq("I16 unload restored the external floor", FillTypeManager.SEND_NUM_BITS, 8)
    ftm:loadMapData()
    for i = 1, 3 do ftm:addFillType({ name = ({ "UNKNOWN", "WHEAT", "UREA" })[i] }) end
    local mission2 = { missionInfo = { mapId = "map01", isValid = false }, cancelLoading = false, terrainDetailHeightId = 0 }
    g_currentMission = mission2
    Mission00.setMissionInfo(mission2, {}, { mods = { { modName = "FS25_StateLedger" } } })
    T.eq("I17 compatible selection reaches the delegate once", delegateCalls, 1)
    local hm = setmetatable({ heightTypeFirstChannel = 0, heightTypeNumChannels = 6, heightTypes = { { index = 1, fillTypeName = "WHEAT", fillTypeIndex = 2, canBeTipped = true } },
        sortHeightTypes = function() end, getTerrainDetailHeightUpdater = function() return {} end }, { __index = DensityMapHeightManager })
    g_densityMapHeightManager = hm
    hm:initialize(true)
    T.eq("I18 native initialize ran once", hm.initialized, 1)
    T.eq("I19 association marked", ctl.groundInitialized, true)
    local ret = FSBaseMission.onFinishedLoading(mission2)
    T.eq("I20 READY freeze calls the native body once and returns its result", ret .. "/" .. tostring(finishedCalls), "native/1")
    T.eq("I21 controller READY", ctl.phase, "READY")
    T.eq("I22 late registration refused after freeze", (ftm:addFillType({ name = "LATE" })), false)
    T.eq("I23 registry unchanged by the refused late add", #ftm.fillTypes, 3)
    T.eq("I24 width unchanged by the refused late add", FillTypeManager.SEND_NUM_BITS, 8)

    -- Admission header on the finished-loading event.
    local ev = { posX = 1, posY = 2, posZ = 3, viewDistanceCoeff = 1 }
    setmetatable(ev, { __index = BaseMissionFinishedLoadingEvent })
    local s = NewStream()
    BaseMissionFinishedLoadingEvent.writeStream(ev, s, nil)
    T.eq("I25 four native floats then the header", s.w, 4 + 37)
    local conn = { sent = {}, sendEvent = function(self, e) self.sent[#self.sent + 1] = e end }
    g_server = { closed = {}, closeConnection = function(self, c) self.closed[#self.closed + 1] = c end }
    local rx = setmetatable({}, { __index = BaseMissionFinishedLoadingEvent })
    BaseMissionFinishedLoadingEvent.readStream(rx, s, conn)
    T.eq("I26 matching peer runs", rx.ran, 1)
    T.eq("I27 matching peer not closed", #g_server.closed, 0)
    -- A peer with another width.
    local s2 = NewStream()
    for _ = 1, 4 do streamWriteFloat32(s2, 0) end
    local h = ctl:getHeader()
    CP.writeHeader(s2, { version = h.version, widthBits = 10, registeredCount = h.registeredCount, formatFlags = h.formatFlags, digest = h.digest })
    local rx2 = setmetatable({}, { __index = BaseMissionFinishedLoadingEvent })
    BaseMissionFinishedLoadingEvent.readStream(rx2, s2, conn)
    T.eq("I28 mismatched peer does not run", rx2.ran, nil)
    T.eq("I29 mismatched peer got answer 8", conn.sent[1].answer, 8)
    T.eq("I30 mismatched peer closed", g_server.closed[1], conn)
    -- Answer 8 on the client: message and one teardown, no native reconnect path.
    local before = quits
    FSBaseMission.onConnectionRequestAnswer(mission2, conn, 8)
    T.ok("I31 answer 8 shows the profile message (English fallback under the key-echo i18n stub)", shown[#shown]:find("differs from the server", 1, true) ~= nil)
    T.eq("I32 answer 8 tears down once", quits, before + 1)
    T.eq("I33 answer 8 never reaches the native handler", mission2.answered, nil)
    FSBaseMission.onConnectionRequestAnswer(mission2, conn, 0)
    T.eq("I34 answer 0 reaches the native handler", mission2.answered, 0)
end

-- (J) Wire validators (format 2).
do
    T.eq("J1 count within bound", WF.countValid(32767, nil), true)
    T.eq("J2 count 32768 refused", WF.countValid(32768, nil), false)
    T.eq("J3 count over registry refused", WF.countValid(300, 256), false)
    T.eq("J4 id within width", WF.idValid(300, 9, 300), true)
    T.eq("J5 id beyond narrower width refused", WF.idValid(300, 8, 300), false)
    T.eq("J6 id zero refused", WF.idValid(0, 9, 300), false)
    local e = { { id = 1, present = true, level = 5 }, { id = 300, present = false } }
    T.eq("J7 valid storage frame", (WF.validateStorageFrame(e, 2, { 1, 300 }, 9, 300)), true)
    T.eq("J8 same count different supported ids refused", select(2, WF.validateStorageFrame(e, 2, { 1, 301 }, 9, 300)), "SET_MISMATCH")
    T.eq("J9 short frame refused", select(2, WF.validateStorageFrame(e, 3, { 1, 300 }, 9, 300)), "INVALID_COUNT")
    T.eq("J10 negative level refused", select(2, WF.validateStorageFrame({ { id = 1, present = true, level = -1 } }, 1, { 1 }, 9, 300)), "INVALID_LEVEL")
    T.eq("J11 unordered ids refused", select(2, WF.validateStorageFrame({ { id = 300, present = false }, { id = 1, present = false } }, 2, { 300, 1 }, 9, 300)), "INVALID_ID")
    T.eq("J12 duplicate ids in a list refused", select(2, WF.validateIdList({ { id = 4 }, { id = 4 } }, 2, 9, 300)), "INVALID_ID")
    T.eq("J13 valid id list", (WF.validateIdList({ { id = 4 }, { id = 9 } }, 2, 9, 300)), true)
    T.eq("J14 adapter seam accepts a named tail", WF.registerTail("ProductionPoint", { read = function() end }), true)
    T.eq("J15 no adapter is bound by default", (function() local n = 0 for _, a in ipairs(CAP.UNBOUND_ADAPTERS) do if a.bound then n = n + 1 end end return n end)(), 0)
end
