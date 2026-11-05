import { clickAt, clickTestId, inputState, key, query, request, screenPos, screenshot, waitFor, waitForServerReady } from "./client";

/// Opens / closes a multi-select from its chevron: its centre can land on a tag's remove button
/// (tag widths follow the system UI font).
async function clickSelectChevron(id: string): Promise<void> {
  const r = await screenPos(id);
  await clickAt(r.x + r.w - 20, r.y + r.h / 2);
}
import { assert, getSessionDir, run, test } from "./runner";
async function controls() {
  const result=await request("POST","/windows/native-input",{action:"uia-tree"});
  assert(result.ok,"UIA selection tree failed"); return result.nodes.filter((node:any)=>node.framework==="Zenit");
}
async function select(name:string,operation="select") {
  return request("POST","/windows/native-input",{action:"uia-select",name,operation});
}
async function refused(name:string,operation:string) {
  let error=""; try { await select(name,operation); } catch(e) { error=String(e); }
  assert(error.includes("UIA Selection failed"),`selection conflict accepted: ${name}/${operation}: ${error}`);
}
test("Windows Selection exposes RadioGroup, commits mutual exclusion and publishes the actual selection event",async()=>{
  await waitForServerReady(15000);
  const before=await request("POST","/windows/native-input",{action:"status"});
  await clickTestId("nav.radio");
  await waitFor(async()=> (await query("story.radio.group"))[0]??null,4000,50);
  const initial=await controls();
  const x=initial.find((n:any)=>n.role===50013&&n.name==="Option X"), y=initial.find((n:any)=>n.role===50013&&n.name==="Option Y");
  assert(x?.selection_item?.selected && !y?.selection_item?.selected,`RadioGroup initial selection missing: ${JSON.stringify(initial.filter((n:any)=>n.role===50013||n.selection))}`);
  const group=initial.find((n:any)=>n.automation_id===x.selection_item.container);
  assert(group?.selection && !group.selection.multiple && group.selection.required && group.selection.ids.length===1 && group.selection.ids[0]===x.automation_id,"RadioGroup selection/container disagrees");
  assert(initial.filter((n:any)=>n.role===50013&&(n.name==="Selected"||n.name==="Unselected")).every((n:any)=>!n.selection_item),"standalone Radio invented an unrelated selection container");
  await refused("Option Y","add"); await refused("Option X","remove");
  assert((await select("Option Y")).selection_committed,"selection event not received");
  await waitFor(async()=> (await query("story.radio.status"))[0]?.text?.includes("y")?true:null,3000,50);
  const afterY=await controls();
  assert(!afterY.find((n:any)=>n.role===50013&&n.name==="Option X").selection_item.selected && afterY.find((n:any)=>n.role===50013&&n.name==="Option Y").selection_item.selected,"RadioGroup selection not mutually exclusive");
  const selectedY=afterY.find((n:any)=>n.automation_id===group.automation_id).selection.ids;
  assert(selectedY.length===1 && selectedY[0]===y.automation_id,"container GetSelection remained stale");
  assert((await screenshot(`${getSessionDir()}/windows-uia-selection-y.png`)).ok,"selected Y screenshot failed");
  await select("Option Y"); await select("Option Y","add"); await select("Option X","remove");
  await select("Option Z"); await select("Option X");
  const final=await controls();
  assert(final.find((n:any)=>n.role===50013&&n.name==="Option X").selection_item.selected && !final.find((n:any)=>n.role===50013&&n.name==="Option Y").selection_item.selected && !final.find((n:any)=>n.role===50013&&n.name==="Option Z").selection_item.selected,"selection round trip not exclusive");
  assert((await screenshot(`${getSessionDir()}/windows-uia-selection-radio.png`)).ok,"selection screenshot failed");
  const after=await request("POST","/windows/native-input",{action:"status"});
  assert(!after.foreground && after.foreground_hwnd===before.foreground_hwnd,"Selection took foreground");
  console.log(`  RadioGroup container, mutual exclusion, Add/Remove rules, idempotence and committed events; foreground=${before.foreground_hwnd}`);
});
async function setItem(node:any,operation:string) {
  const result=await request("POST","/windows/native-input",{action:"uia-select",automation_id:node.automation_id,operation});
  assert(result.selection_committed,`item selection did not commit ${operation}`);
}
async function selectedNames(container:string) {
  return (await controls()).filter((n:any)=>n.selection_item?.container===container && n.selection_item.selected).map((n:any)=>n.name).sort();
}
test("Windows Tree Selection replaces, adds and removes independently of pointer modifiers",async()=>{
  const before=await request("POST","/windows/native-input",{action:"status"});
  await clickTestId("nav.tree");
  await waitFor(async()=> (await query("story.tree.multi"))[0]??null,4000,50);
  let nodes=await controls();
  const a=nodes.find((n:any)=>n.name==="Tree A"), b=nodes.find((n:any)=>n.name==="Tree B"), c=nodes.find((n:any)=>n.name==="Tree C");
  assert(a?.selection_item && b?.selection_item && c?.selection_item,"Tree item selection missing");
  const group=nodes.find((n:any)=>n.automation_id===a.selection_item.container);
  assert(group?.selection.multiple && !group.selection.required,"Tree multi metadata incorrect");
  await setItem(a,"select"); await setItem(b,"add"); await setItem(c,"add");
  assert(JSON.stringify(await selectedNames(group.automation_id))===JSON.stringify(["Tree A","Tree B","Tree C"]),"Tree add discarded other selections");
  await setItem(b,"remove");
  assert(JSON.stringify(await selectedNames(group.automation_id))===JSON.stringify(["Tree A","Tree C"]),"Tree remove changed wrong selection");
  await setItem(a,"select"); // Already selected must still clear Tree C.
  assert(JSON.stringify(await selectedNames(group.automation_id))===JSON.stringify(["Tree A"]),"Tree replace failed for already selected item");
  await setItem(a,"remove");
  assert((await selectedNames(group.automation_id)).length===0,"optional Tree selection could not be cleared");
  await setItem(c,"add");
  assert((await screenshot(`${getSessionDir()}/windows-uia-selection-tree.png`)).ok,"Tree screenshot failed");
  const readme=(await controls()).find((n:any)=>n.name==="README.md");
  await setItem(readme,"select"); await setItem(readme,"remove");
  const after=await request("POST","/windows/native-input",{action:"status"});
  assert(!after.foreground && after.foreground_hwnd===before.foreground_hwnd,"Tree selection took foreground");
});
test("Windows Select single and multiple publish List selection and committed Add/Remove events",async()=>{
  const before=await request("POST","/windows/native-input",{action:"status"});
  await clickTestId("nav.select"); await clickSelectChevron("story.select.multiple-lg");
  await waitFor(async()=> (await controls()).some((n:any)=>n.selection?.multiple && n.role===50008)?true:null,4000,50);
  let nodes=await controls(); const group=nodes.find((n:any)=>n.selection?.multiple && n.role===50008);
  const items=nodes.filter((n:any)=>n.selection_item?.container===group.automation_id);
  const one=items.find((n:any)=>n.name==="Option 1"), two=items.find((n:any)=>n.name==="Option 2"), three=items.find((n:any)=>n.name==="Option 3");
  assert(one?.selection_item.selected && two?.selection_item.selected && !three?.selection_item.selected,"Select initial state wrong");
  await setItem(three,"add"); await setItem(two,"remove"); await setItem(one,"select");
  assert(JSON.stringify(await selectedNames(group.automation_id))===JSON.stringify(["Option 1"]),"Select replace preserved stale selections");
  await setItem(one,"remove"); assert((await selectedNames(group.automation_id)).length===0,"Select empty selection not committed");
  await setItem(three,"add");
  assert((await screenshot(`${getSessionDir()}/windows-uia-selection-list.png`)).ok,"List screenshot failed");
  await clickSelectChevron("story.select.multiple-lg");
  await clickTestId("story.select.clearable");
  await waitFor(async()=> (await controls()).some((n:any)=>n.role===50008 && n.selection && !n.selection.multiple)?true:null,4000,50);
  nodes=await controls(); const single=nodes.find((n:any)=>n.role===50008 && n.selection && !n.selection.multiple);
  const singleItems=nodes.filter((n:any)=>n.selection_item?.container===single.automation_id);
  const singleTwo=singleItems.find((n:any)=>n.name==="Option 2"), singleThree=singleItems.find((n:any)=>n.name==="Option 3");
  await setItem(singleThree,"select");
  let failure=""; try { await setItem(singleTwo,"add"); } catch(error) { failure=String(error); }
  assert(failure.includes("UIA Selection failed"),"Single Select allowed two selected items");
  await setItem(singleThree,"remove");
  assert((await selectedNames(single.automation_id)).length===0,"Single Select clear did not commit");
  assert((await screenshot(`${getSessionDir()}/windows-uia-selection-single.png`)).ok,"Single Select screenshot failed");
  const after=await request("POST","/windows/native-input",{action:"status"});
  assert(!after.foreground && after.foreground_hwnd===before.foreground_hwnd,"List selection took foreground");
});

test("Windows Tabs Selection commits page changes, rejects disabled and conflicting operations, and sibling groups follow the shared model",async()=>{
  await waitForServerReady(15000);
  const before=await request("POST","/windows/native-input",{action:"status"});
  await clickTestId("nav.tabs");
  await waitFor(async()=> (await query("story.tabs.underline"))[0]??null,4000,50);
  const nodes=await controls();
  const overview=nodes.find((n:any)=>n.role===50019 && n.name==="Overview" && n.selection_item);
  assert(overview?.selection_item.selected,"Tabs initial SelectionItem missing");
  const container=overview.selection_item.container;
  const group=nodes.find((n:any)=>n.automation_id===container);
  assert(group?.role===50018 && group.selection.required && !group.selection.multiple && group.selection.ids.length===1 && group.selection.ids[0]===overview.automation_id,"Tab container selection metadata incorrect");
  const items=nodes.filter((n:any)=>n.selection_item?.container===container);
  const details=items.find((n:any)=>n.name==="Details"), settings=items.find((n:any)=>n.name==="Settings"), disabled=items.find((n:any)=>n.name==="Disabled");
  assert(details && settings && disabled && !disabled.enabled,"Tab items/disabled state missing");
  function sharedSiblings(all:any[],own:string) {
    return [...new Set(all.filter((n:any)=>n.role===50019 && n.name==="Overview" && n.selection_item && n.selection_item.container!==own).map((n:any)=>n.selection_item.container))];
  }
  const shared=new Set([container,...sharedSiblings(nodes,container)]);
  const independent=[...new Set(nodes.filter((n:any)=>n.role===50019 && n.selection_item && !shared.has(n.selection_item.container)).map((n:any)=>n.selection_item.container))];
  assert(independent.length===4,`expected four independent Tabs groups, found ${independent.length}`);
  const independentBefore=new Map<string,string>();
  for (const group of independent) independentBefore.set(group,JSON.stringify(await selectedNames(group)));
  async function reject(node:any,operation:string) {
    let error=""; try { await setItem(node,operation); } catch(e) { error=String(e); }
    assert(error.includes("UIA Selection failed"),`Tab invalid selection accepted ${node.name}/${operation}: ${error}`);
  }
  await reject(details,"add"); await reject(overview,"remove"); await reject(disabled,"select");
  await setItem(details,"select");
  await waitFor(async()=> (await query("story.tabs.status"))[0]?.text?.includes("t2")?true:null,3000,50);
  assert(JSON.stringify(await selectedNames(container))===JSON.stringify(["Details"]),"Tab replacement did not deselect Overview");
  const changed=await controls();
  // The story binds its three variant groups (Overview…) to one model signal:
  // the other two follow through the app model. Its four size groups (One…)
  // own separate state and must be untouched by this container's selection.
  const followers=sharedSiblings(changed,container);
  assert(followers.length===2,`expected two shared-model Tabs groups, found ${followers.length}`);
  for (const sibling of followers) assert(JSON.stringify(await selectedNames(sibling))===JSON.stringify(["Details"]),"shared-model Tabs group did not follow");
  for (const [group,names] of independentBefore) assert(JSON.stringify(await selectedNames(group))===names,"Tabs selection leaked into an independent group");
  await setItem(details,"add"); await setItem(overview,"remove");
  await reject(details,"remove");
  await setItem(settings,"select");
  await waitFor(async()=> (await query("story.tabs.status"))[0]?.text?.includes("t3")?true:null,3000,50);
  assert(JSON.stringify(await selectedNames(container))===JSON.stringify(["Settings"]),"Tab Settings selection stale");
  assert((await screenshot(`${getSessionDir()}/windows-uia-selection-tabs.png`)).ok,"Tabs selected screenshot failed");
  await setItem(overview,"select");
  await waitFor(async()=> (await query("story.tabs.status"))[0]?.text?.includes("t1")?true:null,3000,50);
  assert(JSON.stringify(await selectedNames(container))===JSON.stringify(["Overview"]),"Tabs selection round trip failed");
  const after=await request("POST","/windows/native-input",{action:"status"});
  assert(!after.foreground && after.foreground_hwnd===before.foreground_hwnd,
    `Tabs selection took foreground: before=${JSON.stringify(before)}, after=${JSON.stringify(after)}`);
});

test("Windows ComboBox Selection writes the editable value, clears optional selection and invokes the public callback",async()=>{
  await waitForServerReady(15000);
  const before=await request("POST","/windows/native-input",{action:"status"});
  await clickTestId("nav.combobox"); await clickTestId("story.combobox.input"); await key("down");
  await waitFor(async()=> (await controls()).some((n:any)=>n.name==="Banana" && n.selection_item)?true:null,4000,50);
  const nodes=await controls();
  const banana=nodes.find((n:any)=>n.name==="Banana" && n.selection_item);
  const container=banana.selection_item.container;
  const group=nodes.find((n:any)=>n.automation_id===container);
  assert(group?.role===50008 && !group.selection.multiple && !group.selection.required && group.selection.ids.length===0,"ComboBox initial optional selection incorrect");
  const apple=nodes.find((n:any)=>n.name==="Apple" && n.selection_item), kiwi=nodes.find((n:any)=>n.name==="Kiwi" && n.selection_item);
  assert(apple && kiwi && !kiwi.enabled,"ComboBox items missing");
  let error=""; try { await setItem(kiwi,"select"); } catch(e) { error=String(e); }
  assert(error.includes("UIA Selection failed"),"disabled ComboBox option accepted selection");
  await setItem(banana,"select");
  await waitFor(async()=> (await inputState("story.combobox.input")).buffer==="Banana" && (await query("story.combobox.status"))[0]?.text==="ba"?true:null,3000,50);
  await clickTestId("story.combobox.input"); await key("down");
  await waitFor(async()=> (await selectedNames(container)).includes("Banana")?true:null,3000,50);
  error=""; try { await setItem(apple,"add"); } catch(e) { error=String(e); }
  assert(error.includes("UIA Selection failed"),"ComboBox allowed multiple selections");
  await setItem(banana,"add"); await setItem(apple,"remove");
  assert((await inputState("story.combobox.input")).buffer==="Banana","ComboBox idempotent operation mutated text");
  await setItem(banana,"remove");
  await waitFor(async()=> (await inputState("story.combobox.input")).buffer==="" && (await query("story.combobox.status"))[0]?.text==="(none)"?true:null,3000,50);
  assert((await selectedNames(container)).length===0,"ComboBox optional selection did not clear");
  await setItem(apple,"add");
  await waitFor(async()=> (await inputState("story.combobox.input")).buffer==="Apple" && (await query("story.combobox.status"))[0]?.text==="ap"?true:null,3000,50);
  assert((await screenshot(`${getSessionDir()}/windows-uia-selection-combobox.png`)).ok,"ComboBox screenshot failed");
  const after=await request("POST","/windows/native-input",{action:"status"});
  assert(!after.foreground && after.foreground_hwnd===before.foreground_hwnd,"ComboBox selection took foreground");
});

test("Windows ExpandCollapse commits ComboBox popup and Tree visibility with native state events",async()=>{
  await waitForServerReady(15000);
  const before=await request("POST","/windows/native-input",{action:"status"});
  async function expand(node:any,expanded:boolean) {
    const result=await request("POST","/windows/native-input",{action:"uia-expand",automation_id:node.automation_id,expanded});
    assert(result.expansion_committed,"ExpandCollapse state/event not committed");
    const updated=(await controls()).find((n:any)=>n.automation_id===node.automation_id);
    assert(updated?.expand_state===(expanded?1:0),"ExpandCollapse snapshot state disagrees");
  }
  await clickTestId("nav.combobox");
  const combo=(await controls()).find((n:any)=>n.role===50003 && n.name==="Fruit");
  assert(combo?.expand_available && combo.expand_state===0,"closed ComboBox expansion missing");
  await expand(combo,true);
  assert((await controls()).some((n:any)=>n.name==="Banana" && n.selection_item),"expanded ComboBox options missing");
  await expand(combo,true);
  await expand(combo,false);
  assert(!(await controls()).some((n:any)=>n.name==="Banana" && n.selection_item),"collapsed ComboBox options stayed visible to UIA");
  await expand(combo,false); await expand(combo,true);
  assert((await screenshot(`${getSessionDir()}/windows-uia-expanded-combobox.png`)).ok,"expanded ComboBox screenshot failed");
  await expand(combo,false);
  await clickTestId("nav.tree");
  // The story opens with src expanded: collapse it, then expand it again.
  const nodes=await controls(), folder=nodes.find((n:any)=>n.name==="src"), leaf=nodes.find((n:any)=>n.name==="README.md");
  assert(folder?.expand_available && folder.expand_state===1 && leaf && !leaf.expand_available,"Tree folder/leaf expansion metadata incorrect");
  assert(nodes.some((n:any)=>n.name==="main.zig"),"expanded Tree child not exposed");
  function texts(nodes:any[]):string[] {
    return nodes.flatMap((node:any)=>[...(node.text?[node.text]:[]),...texts(node.children??[])]);
  }
  await expand(folder,false); await expand(folder,false);
  assert(texts(await query("story.tree.single")).includes(">") && !texts(await query("story.tree.single")).includes("v"),"collapsed Tree indicator stayed expanded");
  assert(!(await controls()).some((n:any)=>n.name==="main.zig"),"collapsed Tree child exposed");
  await expand(folder,true); await expand(folder,true);
  assert(texts(await query("story.tree.single")).includes("v"),"expanded Tree indicator stayed collapsed");
  assert((await controls()).some((n:any)=>n.name==="main.zig"),"Tree child did not appear");
  assert((await screenshot(`${getSessionDir()}/windows-uia-expanded-tree.png`)).ok,"expanded Tree screenshot failed");
  let error=""; try { await expand(leaf,true); } catch(e) { error=String(e); }
  assert(error.includes("UIA ExpandCollapse failed"),"leaf Tree node accepted expansion");
  const after=await request("POST","/windows/native-input",{action:"status"});
  assert(!after.foreground && after.foreground_hwnd===before.foreground_hwnd,"ExpandCollapse took foreground");
});

test("Windows Select and Accordion ExpandCollapse preserve selection and exclusive group semantics",async()=>{
  await waitForServerReady(15000);
  const before=await request("POST","/windows/native-input",{action:"status"});
  async function expand(node:any,expanded:boolean) {
    console.log(`  expand ${node.name}/${node.automation_id} => ${expanded}`);
    const result=await request("POST","/windows/native-input",{action:"uia-expand",automation_id:node.automation_id,expanded});
    assert(result.expansion_committed,"expansion state/event not committed");
    assert((await controls()).find((n:any)=>n.automation_id===node.automation_id)?.expand_state===(expanded?1:0),"expansion snapshot disagrees");
  }
  await clickTestId("nav.select");
  const select=(await controls()).find((n:any)=>n.role===50003 && n.enabled && n.expand_available);
  assert(select?.expand_state===0,"Select initial expansion missing");
  await expand(select,true); await expand(select,true);
  let nodes=await controls();
  const list=nodes.find((n:any)=>n.role===50008 && n.selection), options=nodes.filter((n:any)=>n.selection_item?.container===list?.automation_id);
  assert(list && options.length>0,"native Select expansion did not expose options");
  const selected=list.selection.ids.slice();
  assert((await screenshot(`${getSessionDir()}/windows-uia-expanded-select.png`)).ok,"Select screenshot failed");
  await expand(select,false); await expand(select,false); await expand(select,true);
  nodes=await controls();
  assert(JSON.stringify(nodes.find((n:any)=>n.automation_id===list.automation_id)?.selection.ids)===JSON.stringify(selected),"Select expansion mutated selection");
  await expand(select,false);
  await clickTestId("nav.accordion");
  nodes=await controls();
  const one=nodes.find((n:any)=>n.name==="Section One" && n.role===50000), two=nodes.find((n:any)=>n.name==="Section Two" && n.role===50000);
  assert(one?.expand_state===1 && two?.expand_state===0,"Accordion initial states missing");
  await expand(two,true); await expand(two,true);
  assert((await controls()).find((n:any)=>n.automation_id===one.automation_id)?.expand_state===1,"nonexclusive Accordion collapsed sibling");
  await expand(two,false); await expand(two,false);
  // The mode is a prerequisite for the exclusivity assertion. A pointer
  // request alone does not prove its callback ran when layout is moving.
  // Invoke the actual accessible button and require its committed event.
  const mode=(await controls()).find((n:any)=>n.role===50000 && n.name==="Use exclusive mode");
  assert(mode?.enabled,"exclusive Accordion mode button unavailable");
  const switched=await request("POST","/windows/native-input",{action:"uia-invoke",name:mode.name});
  assert(switched.invoked_event,"exclusive Accordion mode did not commit its Invoke event");
  const exclusiveOne=one, exclusiveTwo=two;
  assert(exclusiveOne?.expand_available && exclusiveTwo?.expand_available,"exclusive Accordion missing");
  await expand(exclusiveOne,true); await expand(exclusiveTwo,true); await expand(exclusiveTwo,true);
  assert((await controls()).find((n:any)=>n.automation_id===exclusiveOne.automation_id)?.expand_state===0,"exclusive Accordion kept both items expanded");
  assert((await screenshot(`${getSessionDir()}/windows-uia-expanded-accordion.png`)).ok,"Accordion screenshot failed");
  await expand(exclusiveTwo,false);
  const after=await request("POST","/windows/native-input",{action:"status"});
  assert(!after.foreground && after.foreground_hwnd===before.foreground_hwnd,"Select/Accordion expansion took foreground");
});

run();
