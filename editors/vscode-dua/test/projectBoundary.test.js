'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path'),os=require('node:os');
const {analyzeSource}=require('../checker'),host=require('../hostCompletion'),assets=require('../assetCompletion'),modules=require('../moduleIntelligence');
const exe=path.resolve(__dirname,'../bin',process.platform==='win32'?'dua-check.exe':'dua-check');
async function fixture(run){
 const root=fs.mkdtempSync(path.join(os.tmpdir(),'dua-project-boundary-'));
 try {for(const name of ['a','b','a/child'])fs.mkdirSync(path.join(root,name,'scripts'),{recursive:true});
 for(const name of ['a','b','a/child']){fs.writeFileSync(path.join(root,name,'game.zproject'),'{}');fs.writeFileSync(path.join(root,name,'scripts/value.dua'),'export int value = 1;');}
 const a=path.join(root,'a'),b=path.join(root,'b');
 const options={sourceName:path.join(a,'scripts/main.dua'),modulePaths:[path.join(a,'scripts/?.dua')],sourceBoundary:{root:a,markerExtension:'.zproject'}};
 const analyze=(source,extra={})=>analyzeSource(exe,source,{...options,...extra}).promise;
 await run({root,a,b,options,analyze});
 }finally{fs.rmSync(root,{recursive:true,force:true});}
}
test('project checker shares named/relative import targets, definitions and path completion',()=>fixture(async({a,analyze})=>{
 const source='import value as v; import "value.dua" as relative; int ok=v.value;';
 const result=await analyze(source);assert.deepEqual(result.diagnostics,[]);assert.equal(result.imports[0].key,result.imports[1].key);
 assert.equal(modules.definitionAt(source,source.indexOf('value')+1,result,{symbols:{},types:{}}).sourceName.toLowerCase(),path.join(a,'scripts/value.dua').toLowerCase());
 const paths=await analyze('',{importPathPrefix:''});assert.ok(paths.pathCompletions.some(x=>x.label==='value.dua'));
}));
test('boundary rejects escaping imports, overlays, explicit search paths and nested projects',()=>fixture(async({a,b,analyze})=>{
 for(const [source,extra] of [
 ['import "../../b/scripts/value.dua";',{}],
 ['import value;',{modulePaths:[path.join(b,'scripts/?.dua')]}],
 ['import "../child/scripts/value.dua";',{}],
 ['import "../../b/unsaved.dua";',{overlays:[{sourceName:path.join(b,'unsaved.dua'),source:'export int hidden=1;'}]}]
 ]){const r=await analyze(source,extra);assert.ok(r.diagnostics.some(x=>/escapes project|another project/.test(x.message)),JSON.stringify(r));assert.equal(r.imports.length,0);assert.ok(!r.modules.some(x=>x.sourceName.includes('unsaved')));}
 const candidates=await analyze('',{importPathPrefix:'../'});assert.ok(!candidates.pathCompletions.some(x=>x.label.includes('child')));
 assert.deepEqual((await analyze('',{importPathPrefix:'../../b/'})).pathCompletions,[]);
 const host=await analyze('import native;',{hostModules:[{name:'native',exports:[]}]});assert.deepEqual(host.diagnostics,[]);
}));
test('separate projects and legacy requests never inherit another request boundary',()=>fixture(async({a,b,options,analyze})=>{
 const source='import value;';
 const results=await Promise.all([analyze(source),analyze(source,{sourceName:path.join(b,'scripts/main.dua'),modulePaths:[path.join(b,'scripts/?.dua')],sourceBoundary:{root:b,markerExtension:'.zproject'}})]);
 for(const r of results)assert.deepEqual(r.diagnostics,[]);assert.notEqual(results[0].imports[0].key,results[1].imports[0].key);
 assert.deepEqual((await analyze('import "../../b/scripts/value.dua";',{sourceBoundary:undefined})).diagnostics,[]);
 assert.ok((await analyze(source,{sourceName:path.join(b,'scripts/main.dua')})).diagnostics.some(x=>/escapes project/.test(x.message)));
}));
test('project catalog survives stale scene contexts and supplies boundary for new helper files',()=>fixture(async({a})=>{
 const projectFile=path.join(a,'game.zproject'),stat=fs.statSync(projectFile);
 const descriptor={file:'game.zproject',moduleDirectory:'scripts',assetDirectory:'.',sourceBoundary:{root:'.',markerExtension:'.zproject'},sources:[{path:'game.zproject',size:stat.size,modifiedMs:Math.trunc(stat.mtimeMs)}]};
 const catalog={schemaVersion:1,symbols:{},types:{},contexts:[],projectContext:descriptor};
 fs.writeFileSync(path.join(a,'.dua-completion.json'),JSON.stringify(catalog));
 const loaded=host.loadCatalog(a),context=assets.createContext(loaded,path.join(a,'scripts/new.dua'));
 assert.deepEqual(context.moduleDirectories,[path.join(a,'scripts')]);assert.equal(context.sourceBoundary.root,a);assert.deepEqual(context.directories,[a]);
 fs.writeFileSync(projectFile,'changed project');assert.throws(()=>assets.createContext(loaded,path.join(a,'scripts/new.dua')),/stale/);
}));

test('project boundaries reject directory links for imports and completions',()=>fixture(async({a,b,analyze})=>{
 const link=path.join(a,'scripts/linked');
 fs.symlinkSync(path.join(b,'scripts'),link,process.platform==='win32'?'junction':'dir');
 try{
  assert.ok((await analyze('import "linked/value.dua";')).diagnostics.some(d=>/crosses a link/.test(d.message)));
  assert.ok(!(await analyze('',{importPathPrefix:''})).pathCompletions.some(c=>c.label==='linked/'));
 }finally{fs.unlinkSync(link);}
}));

test('explicit child project context does not inherit a stale parent boundary',()=>fixture(async({a})=>{
 const parent={moduleDirectory:'scripts',assetDirectory:'.',sourceBoundary:{root:'.',markerExtension:'.zproject'},sources:[{path:'missing.zproject'}]};
 const child={moduleDirectory:'child/scripts',assetDirectory:'child',sourceBoundary:{root:'child',markerExtension:'.zproject'},sources:[{path:'child/game.zproject'}]};
 const c={root:a,symbols:{},types:{},contexts:[],projectContexts:[parent,child]};
 const selected=assets.createContext(c,path.join(a,'child/scripts/main.dua'));
 assert.equal(selected.sourceBoundary.root,path.join(a,'child'));
 assert.deepEqual(selected.moduleDirectories,[path.join(a,'child/scripts')]);
 const r=await analyzeSource(exe,'import value;',{sourceName:path.join(a,'child/scripts/main.dua'),modulePaths:[path.join(selected.moduleDirectories[0],'?.dua')],sourceBoundary:selected.sourceBoundary}).promise;
 assert.deepEqual(r.diagnostics,[]);assert.ok(r.imports[0].key.includes('child'));
}));
