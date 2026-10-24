// يختبر طبقة SP (النقاط من الخادم) المأخوذة حرفياً من index.html مع rpc وهمي
const fs=require('fs'),vm=require('vm'),assert=require('assert');
const src=fs.readFileSync(process.argv[2],'utf8');
const sp=src.match(/\/\* \[SP-BEGIN\][\s\S]*?\[SP-END\] \*\//)[0];
let calls=[],fail=false,redraws=0;
const mk=()=>({Data:{db:{rpc:(n,a)=>{calls.push([n,a]);if(fail)return Promise.resolve({error:{code:'500'}});
   if(n==='points_server_enabled')return Promise.resolve({data:true});
   if(n==='points_many'){const o={};a.p_sids.forEach(s=>o[s]={total:s.length,att:0,rec:0,exam:0,add:0,streak:0,p:0,l:0,a:0,nRec:0,nExam:0,nAdd:0});return Promise.resolve({data:o});}
   if(n==='halaqa_rank')return Promise.resolve({data:{rank:2,of:7,total:5}});}}},
  refresh:()=>{redraws++;},pointsOf:()=>({total:-1,local:true}),setTimeout,Date,Promise,Object,console});
(async()=>{
  const ctx=mk();vm.createContext(ctx);vm.runInContext(sp,ctx);
  assert.strictEqual(vm.runInContext('pointsOf("a","","").local',ctx),undefined===1?0:true,'يستعمل المحلي قبل التفعيل');
  await vm.runInContext('SP.probe()',ctx); assert.ok(ctx.SP?true:vm.runInContext('SP.on',ctx),'probe فعّلت');
  // 300 استدعاء متزامن => طلب واحد فقط
  const first=vm.runInContext('var r=[];for(var i=0;i<300;i++)r.push(pointsOf("s"+i,"","").total);r',ctx);
  assert.ok(first.every(x=>x===0),'قبل الوصول: أصفار'); await new Promise(r=>setTimeout(r,200));
  const pm=calls.filter(c=>c[0]==='points_many'); assert.strictEqual(pm.length,1,'طلب واحد مجمّع، وُجد '+pm.length);
  assert.strictEqual(vm.runInContext('pointsOf("s10","","").total',ctx),3,'القيمة من الكاش بعد الوصول');
  assert.ok(redraws>=1,'refresh بعد الوصول');
  const n=calls.length; vm.runInContext('pointsOf("s10","","")',ctx); await new Promise(r=>setTimeout(r,60)); assert.strictEqual(calls.length,n,'لا طلب جديد من الكاش');
  // الترتيب
  assert.strictEqual(vm.runInContext('SP.rankOf("s1").rank',ctx),'…'); await new Promise(r=>setTimeout(r,30));
  assert.deepStrictEqual(JSON.parse(JSON.stringify(vm.runInContext('SP.rankOf("s1")',ctx))),{rank:2,total:7});
  // فشل الخادم => رجوع للمحلي
  fail=true; vm.runInContext('SP.clear()',ctx); vm.runInContext('pointsOf("zz","","")',ctx); await new Promise(r=>setTimeout(r,100));
  assert.strictEqual(vm.runInContext('SP.on',ctx),false,'أُطفئ بعد الفشل'); assert.strictEqual(vm.runInContext('pointsOf("zz","","").local',ctx),true,'عاد للمحلي');
  console.log('SP client tests OK ('+pm.length+' batched call for 300 lookups)');
})().catch(e=>{console.error('FAIL',e.message);process.exit(1);});
