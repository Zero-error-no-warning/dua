'use strict';

// Canonical null-exclusion spelling from dua.type_syntax; opaque base IDs are preserved.
function nonNullInner(type) {
  if (typeof type!=='string' || !type.startsWith('(') || !type.endsWith(' & !null)')) return null;
  let depth=0,quoted=false,escaped=false;
  for(let i=0;i<type.length;i++) {
    const char=type[i];
    if(quoted) {if(escaped)escaped=false;else if(char==='\\')escaped=true;else if(char==='"')quoted=false;continue;}
    if(char==='"')quoted=true;
    else if(char==='(')depth++;
    else if(char===')' && --depth===0 && i!==type.length-1)return null;
  }
  return depth===0 ? type.slice(1,-9) : null;
}
function withoutNullExclusion(type) {
  for(let i=0;i<32;i++){const inner=nonNullInner(type);if(inner===null)return type;type=inner;}
  return type;
}

// Mirrors only the confirmed type annotation grammar, not expression semantics or null checks.
function readType(input,start,resolveName,depth=0) {
  if(depth>32)return null;
  let next=start,type,known=true;
  if(input[next]?.text==='(') {
    const inner=readType(input,next+1,resolveName,depth+1);
    if(!inner || input[inner.next]?.text!==')')return null;
    ({type,known}=inner);next=inner.next+1;
  } else if(input[next]?.kind==='string' && input[next].closed && !input[next].interpolated) {
    type=JSON.stringify(input[next++].value);
  } else if(input[next]?.kind==='identifier') {
    let name=input[next++].text;
    while(input[next]?.text==='.' && input[next+1]?.kind==='identifier') {name+='.'+input[next+1].text;next+=2;}
    type=name==='null' ? 'null' : resolveName(name);
    known=!!type;type ||= name;
  } else return null;
  while(input[next]?.text==='[') {
    next++;
    let key='';
    if(input[next]?.text!==']') {
      const item=readType(input,next,resolveName,depth+1);if(!item)return null;
      key=item.type;known &&= item.known;next=item.next;
    }
    if(input[next]?.text!==']')return null;
    type+='['+key+']';next++;
  }
  if(input[next]?.text==='delegate') {
    if(input[++next]?.text!=='(')return null;
    next++;const parameters=[];
    while(input[next]?.text!==')') {
      const parameter=readType(input,next,resolveName,depth+1);if(!parameter)return null;
      parameters.push(parameter.type);known &&= parameter.known;next=parameter.next;
      if(input[next]?.text!==',')break;next++;
    }
    if(input[next]?.text!==')')return null;
    type+=' delegate('+parameters.join(',')+')';next++;
  }
  if(input[next]?.text==='&') {
    if(input[next+1]?.text!=='!' || input[next+2]?.text!=='null')return null;
    type='('+type+' & !null)';next+=3;
  }
  return {type,known,next};
}
function splitContainer(type) {
  if(typeof type!=='string' || !type.endsWith(']'))return null;
  let depth=0,parentheses=0,start=-1,quoted=false,escaped=false;
  for(let i=0;i<type.length;i++) {
    const char=type[i];
    if(quoted){if(escaped)escaped=false;else if(char==='\\')escaped=true;else if(char==='"')quoted=false;continue;}
    if(char==='"')quoted=true;
    else if(char==='(')parentheses++;
    else if(char===')')parentheses--;
    else if(!parentheses && char==='['){if(depth++===0)start=i;}
    else if(!parentheses && char===']' && --depth===0 && i===type.length-1 && start>0)
      return {element:type.slice(0,start),key:type.slice(start+1,-1)};
  }
  return null;
}
module.exports={readType,nonNullInner,withoutNullExclusion,splitContainer};
