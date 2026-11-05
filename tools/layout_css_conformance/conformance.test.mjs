import test from 'node:test';
import assert from 'node:assert/strict';
import {parseSuite,html,styleCSS,compare,summarize,loadSuite,classifyEngineDeviations,reportsFailed,runNative} from './conformance.mjs';
const f = {id:'fixture',properties:['grow'],width:300,height:100,root:{id:'root',style:{width:{px:300},height:{px:100},direction:'row'},children:[{id:'a',style:{width:{grow:{min:250}},height:{px:20}}}]}};
test('parse fixture tree; reject duplicates, unknown properties and invalid sizing', () => {
  assert.equal(parseSuite(JSON.stringify({version:1,fixtures:[f]})).fixtures[0].root.children[0].id,'a');
  for (const mutate of [s=>s.version=2,s=>s.fixtures.push(f),s=>s.fixtures[0].root.children.push({id:'a'}),s=>s.fixtures[0].root.style.widht=3,s=>s.fixtures[0].root.style.width={bogus:1}]) {
    const s = structuredClone({version:1,fixtures:[f]});mutate(s);assert.throws(()=>parseSuite(s));
  }
});
test('CSS mapping preserves flex constraints, explicit zero basis, defaults and escapes HTML', () => {
  const css = styleCSS({width:{grow:{min:250}},height:{px:20},flex_basis:0},{direction:'row'});
  assert.match(css,/min-width:250px/);assert.match(css,/flex-grow:1/);assert.match(css,/flex-basis:0px/);
  assert.doesNotMatch(css,/min-height:0px/); // Do not erase CSS automatic minimum for px.
  const copy = structuredClone(f);copy.root.children[0].text={content:'<script>"&'};
  const markup = html(copy,'http://127.0.0.1/font.ttf');assert.match(markup,/&lt;script&gt;&quot;&amp;/);
  assert.match(markup,/flex-direction:row/);
});
test('auto margins use top/right/bottom/left bits; no_cross_stretch preserves center', () => {
  assert.match(styleCSS({margin_auto_mask:8}),/margin-left:auto/);
  assert.doesNotMatch(styleCSS({no_cross_stretch:true},{align_items:'center'}),/align-self/);
  assert.match(styleCSS({no_cross_stretch:true},{align_items:'stretch'}),/align-self:flex-start/);
});
test('comparison uses inclusive 0.5px tolerance and detects missing/extra/non-finite nodes', () => {
  const local = {...f,root:{id:'a'}};
  const a = [{id:'a',x:0,y:0,w:100,h:20}];
  assert.equal(compare(local,a,[{...a[0],x:.5}]).match,true);
  assert.equal(compare(local,a,[{...a[0],w:100.501}]).match,false);
  assert.equal(compare(local,a,[]).match,false);assert.equal(compare(local,[],a).match,false);
  assert.equal(compare(local,a,[{...a[0],w:NaN}]).match,false);
  const result = compare({...local,must_match:true},a,a);assert.equal(result.must_match,true);
  assert.equal(compare(local,[],[]).match,false);
  assert.throws(()=>compare(local,[...a,...a],a),/Duplicate/);
  assert.deepEqual(summarize([result]),{grow:{fixtures:1,different:0,knownDeviations:0,nodes:1,differentNodes:0}});
});
test('committed corpus validates with unique ids and covers all section 7.1 categories', () => {
  const s = loadSuite(new URL('./fixtures.json',import.meta.url));
  assert.ok(s.fixtures.length>=60);assert.ok(s.fixtures.filter(f=>f.must_match).length>=10);
  for (const p of ['grow','shrink','auto-min','cross','no-cross-stretch','wrap','baseline','gap','flex-basis','fit','percent','border','aspect-ratio','margin-auto','grid','layout-isolation','translate','sticky','text']) assert.ok(s.fixtures.some(f=>f.properties.includes(p)),p);
});
test('HTML grid, border and text mappings expose CSS semantics without emulating bugs', () => {
  const css = styleCSS({grid:{columns:[{fr:1},{px:50},'auto'],rows:[{px:40}],column_gap:10},border:{width:2,side_widths:[-1,5,-1,0]}});
  assert.match(css,/grid-template-columns:1fr 50px auto/);
  assert.match(css,/border-top-width:2px/);assert.match(css,/border-right-width:5px/);assert.match(css,/border-left-width:0px/);
  const text = styleCSS({width:{px:90},height:{fit:{}}},null,{content:'full source',wrap:'word',max_lines:2,fade_right:20});
  assert.match(text,/-webkit-line-clamp:2/);assert.match(text,/mask-image:linear-gradient/);
});

test('LC3 basis auto/content and explicit zero stay distinct', () => {
  assert.match(styleCSS({width:{grow:{}}},{direction:'row'}), /flex-basis:auto/);
  assert.match(styleCSS({flex_basis:'content'}), /flex-basis:content/);
  assert.match(styleCSS({flex_basis:0}), /flex-basis:0px/);
  const s = structuredClone({version:1,fixtures:[f]});
  s.fixtures[0].root.style.flex_basis = 'bogus';
  assert.throws(()=>parseSuite(s), /Invalid flex basis/);
});


test('known engine deviation schema requires engine, reason and reference', () => {
  const valid = structuredClone({version:1,fixtures:[f]});
  valid.fixtures[0].known_engine_deviation = {webkit:'Measured WebKit difference; CSS reference https://www.w3.org/TR/css-flexbox-1/#resolve-flexible-lengths'};
  assert.doesNotThrow(() => parseSuite(valid));
  for (const value of [null,[],{safari:'why https://example.com'},{webkit:''},{webkit:'No reference'},{webkit:7}]) {
    const bad = structuredClone(valid);bad.fixtures[0].known_engine_deviation = value;
    assert.throws(() => parseSuite(bad), /deviation/);
  }
});
function deviationReports(marked=true) {
  const local = {...f,root:{id:'a'},must_match:true,known_engine_deviation:marked ? {webkit:'Known WebKit behavior; https://www.w3.org/TR/css-flexbox-1/#resolve-flexible-lengths'} : {}};
  const a = [{id:'a',x:0,y:0,w:100,h:20}];
  return ['chromium','firefox','webkit'].map(engine => ({engine,status:'measured',fixtures:[compare(local,a,[{...a[0],w:engine === 'webkit' ? 110 : 100}])]}));
}
test('marked engine difference is reported separately with two matching controls', () => {
  const reports = deviationReports();classifyEngineDeviations(reports);
  const webkit = reports[2], result = webkit.fixtures[0];
  assert.equal(result.match,false); // Raw geometry and must_match stay intact.
  assert.equal(result.must_match,true);
  assert.deepEqual(result.knownDeviation.corroboratingEngines,['chromium','firefox']);
  assert.equal(webkit.summary.grow.knownDeviations,1);
  assert.equal(webkit.summary.grow.different,0);
  assert.equal(reportsFailed(reports,{enforce:true,requireAll:true}),false);
});
test('unmarked difference and annotated difference without two controls still fail', () => {
  for (const reports of [deviationReports(false),deviationReports().slice(1),deviationReports().slice(2)]) {
    classifyEngineDeviations(reports);
    assert.equal(reportsFailed(reports,{enforce:true}),true);
    assert.equal(reports.at(-1).fixtures[0].knownDeviation,undefined);
  }
});
test('annotations never hide missing or non-finite nodes, measurement errors or unavailable engines', () => {
  for (const mutate of [r=>r[2].fixtures[0].nodes[0].browser=null,r=>r[2].fixtures[0].nodes[0].browser.w=NaN,r=>r[2].status='error']) {
    const reports=deviationReports();mutate(reports);classifyEngineDeviations(reports);
    assert.equal(reportsFailed(reports,{enforce:true,requireAll:true}),true);
  }
  const unavailable=['chromium','firefox','webkit'].map(engine=>({engine,status:'unavailable',fixtures:[]}));
  assert.equal(reportsFailed(unavailable),true);
  assert.equal(reportsFailed(unavailable,{enforce:true,requireAll:true}),true);
  const reports=deviationReports();reports[2].status='unavailable';reports[2].fixtures=[];
  classifyEngineDeviations(reports);
  assert.equal(reportsFailed(reports,{enforce:true,requireAll:true}),true);
});

test('two controls must agree with each other within the unchanged tolerance', () => {
  const reports=deviationReports();
  reports[0].fixtures[0].nodes[0].browser.w=99.5;
  reports[1].fixtures[0].nodes[0].browser.w=100.5;
  classifyEngineDeviations(reports);
  assert.equal(reports[2].fixtures[0].knownDeviation,undefined);
  assert.equal(reportsFailed(reports,{enforce:true}),true);
});


test('complete success records cannot hide a missing fixture, crash, timeout or leak failure', () => {
  const good=deviationReports();
  for (const r of good) for (const f of r.fixtures) f.match=true;
  const options={enforce:true,requireAll:true,expectedFixtureIds:[good[0].fixtures[0].id]};
  assert.equal(reportsFailed(good,options),false);
  const missing=structuredClone(good);missing[2].fixtures=[];
  assert.equal(reportsFailed(missing,options),true);
  for(const error of ['crashed after success marker','timed out after success marker','allocator leak after success marker']) {
    const failed=structuredClone(good);failed[2].status='error';failed[2].error=error;
    assert.equal(reportsFailed(failed,options),true);
  }
});

test('text oracle pins CoreText-compatible shaping controls and baseline spelling', () => {
  const css = styleCSS({align_items:'first_baseline',align_content:'space_around'}, null, {content:'office AV'});
  for (const fragment of ['font-kerning:normal','font-feature-settings:normal','font-variant-ligatures:common-ligatures contextual no-discretionary-ligatures no-historical-ligatures','letter-spacing:0px','word-spacing:0px','text-rendering:optimizeLegibility','font-synthesis:none','font-optical-sizing:none','-webkit-text-size-adjust:100%','align-items:first baseline','align-content:space-around']) assert.ok(css.includes(fragment), fragment);
});

test('orthogonal differences do not substitute for two complete agreeing controls', () => {
  const reports = deviationReports();
  reports[1].fixtures[0].known_engine_deviation.firefox = 'Rounding https://www.w3.org/TR/CSS2/visudet.html#leading';
  reports[1].fixtures[0].nodes[0].browser.y = 1.2;
  reports[1].fixtures[0].match = false;
  classifyEngineDeviations(reports);
  for (const r of reports) assert.equal(r.fixtures[0].knownDeviation, undefined);
  assert.equal(reportsFailed(reports, {enforce:true}), true);
});
test('duplicate control engine cannot satisfy two-engine rule', () => {
  const reports = deviationReports();reports[1].engine = 'chromium';
  classifyEngineDeviations(reports);
  assert.equal(reports[2].fixtures[0].knownDeviation, undefined);
  assert.equal(reportsFailed(reports, {enforce:true}), true);
});
test('explicit report-only with a note is legal and preserves raw differences', () => {
  const suite = {version:1,fixtures:[{...f,must_match:false,note:'Measured engine disagreement'}]};
  assert.doesNotThrow(()=>parseSuite(suite));
  for (const note of ['','  ',42]) {
    const bad=structuredClone(suite);bad.fixtures[0].note=note;
    assert.throws(()=>parseSuite(bad), /note/);
  }
  const reports=deviationReports(false);
  reports[2].fixtures[0].must_match=false;
  assert.equal(reportsFailed(reports,{enforce:true}),false);
  assert.equal(reports[2].fixtures[0].match,false);
});

function specificationReports() {
  const reports = deviationReports();
  // Two pinned engines agree with an older specification. A numeric normative
  // contract plus an independent matching engine rejects this majority.
  for (const report of reports) {
    const f = report.fixtures[0];
    f.spec_rects = [{id:'a',x:0,y:0,w:100,h:20}];
    f.spec_reference = 'https://www.w3.org/TR/2026/WD-css-align-3-20261008/#overflow-values';
    f.known_engine_deviation = {chromium:'Old physical start https://www.w3.org/TR/css-align-3/#overflow-values',firefox:'Old physical start https://www.w3.org/TR/css-align-3/#overflow-values'};
    f.nodes[0].browser.w = report.engine === 'webkit' ? 100 : 110;
    f.match = report.engine === 'webkit';
  }
  return reports;
}

test('specification contract plus one engine cannot excuse a two-engine disagreement', () => {
  const reports=specificationReports();classifyEngineDeviations(reports);
  assert.equal(reportsFailed(reports,{enforce:true,requireAll:true}),true);
  for (const r of reports) assert.equal(r.fixtures[0].knownDeviation,undefined);
});

test('real native subprocess rejects crash timeout and leak after complete geometry markers', () => {
  const success = 'console.log(JSON.stringify({fixtures:[{id:"ok",nodes:[{id:"root",x:0,y:0,w:100,h:20}]}]}));';
  const run = (body,options) => runNative(process.execPath,['-e',success+body],options);
  assert.doesNotThrow(()=>run(''));
  assert.throws(()=>run('process.exit(3);'), /Zenit failed/);
  assert.throws(()=>run('process.kill(process.pid,"SIGKILL");'), /Zenit failed/);
  // The timeout case must print first: use a long enough deadline for Node to
  // start, then verify the captured complete marker survives in the error.
  assert.throws(()=>run('setInterval(()=>{},1000);',{timeout:2000}), error=>/Zenit failed/.test(error.message) && /"fixtures"/.test(error.message) && /SIGKILL/.test(error.message));
  for (const diagnostic of ['error: memory address 0x123 leaked','[gpa] (err): memory leak','error: allocation leak','panic: bad']) {
    assert.throws(()=>run('console.error('+JSON.stringify(diagnostic)+');'), error=>/Zenit failed/.test(error.message) && /"fixtures"/.test(error.message));
  }
});

test('LC3C grid minmax, relative/static and explicit text break controls map to CSS', () => {
  assert.match(styleCSS({},null,{content:'longword',wrap:'char',overflow_wrap:'normal',word_break:'normal'}),/overflow-wrap:anywhere/);
  assert.match(styleCSS({},null,{content:'longword',wrap:'break_all',overflow_wrap:'normal',word_break:'normal'}),/word-break:break-all/);
  assert.match(styleCSS({grid:{columns:[{minmax:{}}],rows:[]}}),/grid-template-columns:minmax\(auto,auto\)/);
  assert.match(styleCSS({grid:{columns:[{minmax:{min:{px:0},max:{fr:1}}},'auto'],rows:[{px:20}]}}),/grid-template-columns:minmax\(0px,1fr\) auto/);
  assert.match(styleCSS({position:'static',inset:{left:{px:20}}}),/position:static/);
  assert.match(styleCSS({position:'relative',inset:{right:{percent:10}}}),/right:10%/);
  assert.match(styleCSS({},null,{content:'a',wrap:'word',overflow_wrap:'break_word'}),/overflow-wrap:break-word/);
  assert.match(styleCSS({},null,{content:'a',wrap:'word',word_break:'break_all'}),/word-break:break-all/);
  assert.match(styleCSS({},null,{content:'a',wrap:'char'}),/overflow-wrap:anywhere/);
  assert.doesNotMatch(styleCSS({border:{width:10,overlay:true}}),/border-(top|right|bottom|left)-width/);
});

test('LC3C rejects invalid track breadths and break controls before measurement', () => {
  for (const track of [{fr:-1},{px:Infinity},{minmax:{min:{fr:1},max:{fr:1}}},{minmax:{min:{px:0},max:{fr:1},bogus:2}},'min_content']) {
    const fixture=structuredClone(f); fixture.root.style.grid={columns:[track]};
    assert.throws(()=>parseSuite({version:1,fixtures:[fixture]}));
  }
  for(const [key,value] of [['overflow_wrap','break_all'],['word_break','anywhere']]){
    const fixture=structuredClone(f); fixture.root.text={content:'longword',wrap:'word',[key]:value};
    assert.throws(()=>parseSuite({version:1,fixtures:[fixture]}));
  }
});

test('LC3C retains every previously required fixture and requires all new contracts', () => {
  const suite=loadSuite(new URL('./fixtures.json',import.meta.url));
  const prior=["grow-min", "grow-auto-min", "grow-max", "grow-weight-small", "grow-weight", "shrink-min", "shrink-grow", "shrink-weight", "default-min", "overflow-hidden", "overflow-enum-hidden", "cross-grow-start", "cross-grow-center", "cross-grow-end", "cross-grow-stretch", "stretch-minmax", "no-cross-center", "no-cross-stretch", "no-cross-explicit", "wrap-grow", "wrap-shrink", "wrap-align-self", "wrap-no-cross", "wrap-explicit-cross", "wrap-reverse", "wrap-257", "gap-space_between", "gap-overflow-space_between", "gap-space_around", "gap-overflow-space_around", "gap-space_evenly", "gap-overflow-space_evenly", "basis-grow", "basis-zero", "basis-positive", "fit-main", "percent-padding", "absolute-inset", "aspect-width", "auto-margin", "auto-margin-grow-max", "auto-margin-cross", "grid-basic", "grid-span", "isolation", "translate", "sticky-zero-scroll", "display-none", "margin-padding", "direction-row", "direction-column", "direction-row_reverse", "direction-column_reverse", "col-wrap", "baseline-box", "stretch-grow-max", "stretch-fit-ext-max", "wrap-no-cross-leaf", "justify-start", "justify-end", "justify-center", "grow-own-max", "grow-partial-freeze", "shrink-small-factor", "freeze-mixed-violations", "basis-auto-content", "basis-content-content", "basis-0-content", "explicit-zero-min", "text-word-auto-min", "text-nowrap-auto-min", "grow-min-column", "grow-min-row_reverse", "grow-min-column_reverse", "min-wins-max", "basis-grow-shrink", "overflow-auto-min", "overflow-scroll-min", "text-char-min", "text-word-min", "column-text-auto-min", "grow-padding-basis-zero", "grow-cap-justify-center", "grow-cap-justify-space_between", "grow-cap-justify-space_around", "grow-cap-justify-space_evenly", "auto-margin-grow-max-row_reverse", "auto-margin-grow-max-column_reverse", "lc3b-lines-row-normal", "lc3b-lines-row-normal-reverse", "lc3b-lines-row-start", "lc3b-lines-row-start-reverse", "lc3b-lines-row-end", "lc3b-lines-row-end-reverse", "lc3b-lines-row-center", "lc3b-lines-row-center-reverse", "lc3b-lines-row-stretch", "lc3b-lines-row-stretch-reverse", "lc3b-lines-row-space_between", "lc3b-lines-row-space_between-reverse", "lc3b-lines-row-space_around", "lc3b-lines-row-space_around-reverse", "lc3b-lines-row-space_evenly", "lc3b-lines-row-space_evenly-reverse", "lc3b-self-row-start", "lc3b-self-row-end", "lc3b-self-row-center", "lc3b-self-row-stretch", "lc3b-auto-cross-row-1", "lc3b-auto-cross-overflow-row-1", "lc3b-auto-cross-row-4", "lc3b-auto-cross-overflow-row-4", "lc3b-auto-cross-row-5", "lc3b-auto-cross-overflow-row-5", "lc3b-overflow-row-start", "lc3b-overflow-row-end", "lc3b-overflow-row-center", "lc3b-overflow-row-space_between", "lc3b-overflow-row-space_around", "lc3b-overflow-row-space_evenly", "lc3b-overflow-row_reverse-start", "lc3b-overflow-row_reverse-end", "lc3b-overflow-row_reverse-center", "lc3b-overflow-row_reverse-space_between", "lc3b-freeze-row-wrap", "lc3b-main-auto-row-wrap", "lc3b-freeze-row-wrap_reverse", "lc3b-main-auto-row-wrap_reverse", "lc3b-lines-column-normal", "lc3b-lines-column-normal-reverse", "lc3b-lines-column-start", "lc3b-lines-column-start-reverse", "lc3b-lines-column-end", "lc3b-lines-column-end-reverse", "lc3b-lines-column-center", "lc3b-lines-column-center-reverse", "lc3b-lines-column-stretch", "lc3b-lines-column-stretch-reverse", "lc3b-lines-column-space_between", "lc3b-lines-column-space_between-reverse", "lc3b-lines-column-space_around", "lc3b-lines-column-space_around-reverse", "lc3b-lines-column-space_evenly", "lc3b-lines-column-space_evenly-reverse", "lc3b-self-column-start", "lc3b-self-column-end", "lc3b-self-column-center", "lc3b-self-column-stretch", "lc3b-auto-cross-column-8", "lc3b-auto-cross-overflow-column-8", "lc3b-auto-cross-column-2", "lc3b-auto-cross-overflow-column-2", "lc3b-auto-cross-column-10", "lc3b-auto-cross-overflow-column-10", "lc3b-overflow-column-start", "lc3b-overflow-column-end", "lc3b-overflow-column-center", "lc3b-overflow-column-space_between", "lc3b-overflow-column-space_around", "lc3b-overflow-column-space_evenly", "lc3b-overflow-column_reverse-start", "lc3b-overflow-column_reverse-end", "lc3b-overflow-column_reverse-center", "lc3b-overflow-column_reverse-space_between", "lc3b-freeze-column-wrap", "lc3b-main-auto-column-wrap", "lc3b-freeze-column-wrap_reverse", "lc3b-main-auto-column-wrap_reverse", "lc3b-wrap-text-flex", "lc3b-cross-min-wins-no_wrap", "lc3b-cross-min-wins-wrap", "lc3b-line-overflow-wrap-center", "lc3b-line-overflow-wrap-end", "lc3b-line-overflow-wrap-space_between", "lc3b-line-overflow-wrap-space_around", "lc3b-line-overflow-wrap-space_evenly", "lc3b-cross-min-wins-wrap_reverse", "lc3b-line-overflow-wrap_reverse-center", "lc3b-line-overflow-wrap_reverse-end", "lc3b-line-overflow-wrap_reverse-space_between", "lc3b-nested-first-line", "lc3b-baseline-fixed-text", "lc3b-fit-cross-wrapped-text", "lc3b-fit-cross-nested-center", "lc3b-baseline-small-leading-no_wrap", "lc3b-baseline-small-leading-wrap", "lc3b-baseline-small-leading-wrap_reverse", "lc3b-baseline-negative-margin-no_wrap", "lc3b-baseline-negative-margin-wrap", "lc3b-baseline-negative-margin-wrap_reverse"];
  for(const id of prior)assert.equal(suite.fixtures.find(f=>f.id===id)?.must_match,true,id);
  const added=suite.fixtures.filter(f=>f.id.startsWith('lc3c-'));
  assert.equal(added.length,48);
  for(const fixture of added)assert.equal(fixture.must_match,true,fixture.id);
});
