// Regenerate the self-contained Japanese reference. Requires only Node.js.
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const dir = dirname(fileURLToPath(import.meta.url));
const esc = s => String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const sourceLinks = new Map();
const allSections = [];
const readSections = (file, prefix) => {
  const text = readFileSync(join(dir, file), 'utf8').replace(/\r/g, '');
  const parts = text.split(/^## /m).slice(1);
  const sections = parts.map((part, i) => {
    const end = part.indexOf('\n');
    return { id: prefix + '-' + (i + 1), title: part.slice(0, end).replace(/^\d+\.\s*/, ''), body: part.slice(end + 1), file };
  });
  sourceLinks.set(file, '#' + sections[0].id);
  return sections;
};
const language = readSections('language-reference-ja.md', 'language');
const host = readSections('embedding-api-ja.md', 'host');
const extra = readSections('reference-examples-ja.md', 'guide');
const groups = [
  { title: 'はじめに', sections: extra.slice(0, 1) },
  { title: '言語仕様', sections: language },
  { title: '標準ライブラリ詳解', sections: extra.slice(1, 5) },
  { title: 'D への組み込み', sections: host },
  { title: '使いこなす', sections: extra.slice(5) }
];
groups.forEach(g => g.sections.forEach(s => { s.group = g.title; allSections.push(s); }));
sourceLinks.set('public-guide-ja.md', '#guide-1');

function inline(text) {
  const pieces = [];
  const token = html => '\u0000' + (pieces.push(html) - 1) + '\u0000';
  text = text.replace(/`([^`]+)`/g, (_, v) => token('<code>' + esc(v) + '</code>'));
  text = text.replace(/\[([^\]]+)\]\(([^)]+)\)/g, (_, label, url) => {
    const safe = sourceLinks.get(url) || url;
    if (!/^(https?:|#|\.\.\/|[a-zA-Z0-9_-])/.test(safe) || /^(javascript|data):/i.test(safe)) return label;
    return token('<a href="' + esc(safe) + '">' + esc(label) + '</a>');
  });
  return esc(text).replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
    .replace(/\u0000(\d+)\u0000/g, (_, i) => pieces[Number(i)]);
}

function highlight(code) {
  const tokens = /\/\+[\s\S]*?\+\/|\/\/[^\n]*|#[^\n]*|"[^"\n]*"|\b(?:auto|int|long|double|bool|string|any|void|array|table|struct|class|alias|delegate|return|if|else|while|for|foreach|switch|case|default|break|continue|try|catch|yield|import|export|as|is|cast|this|new|true|false|null)\b|\b\d+(?:\.\d+)?\b/g;
  let out = '', cursor = 0;
  for (const m of code.matchAll(tokens)) {
    const value = m[0];
    const cls = /^(\/\/|\/\+|#)/.test(value) ? 'comment' : value[0] === '"' ? 'str' : /^\d/.test(value) ? 'num' : 'kw';
    out += esc(code.slice(cursor, m.index)) + '<span class="' + cls + '">' + esc(value) + '</span>';
    cursor = m.index + value.length;
  }
  return out + esc(code.slice(cursor));
}

let codeCount = 0;
function codeBlock(code, lang) {
  codeCount++;
  const label = lang === 'D' || lang === 'dua' ? 'Dua' : lang === 'd' ? 'D · ホスト側' : 'Shell';
  return '<figure class="code-block"><figcaption><span>' + label + '</span><button type="button" class="copy" aria-label="コードをコピー">コピー</button></figcaption><pre tabindex="0"><code class="language-' + esc(lang) + '">' + highlight(code) + '</code></pre></figure>';
}

// This deliberately small Markdown renderer supports the constructs in our three
// source documents. Inline-code pipes are protected before splitting table cells.
const cells = line => {
  const codes = [];
  return line.trim().replace(/^\||\|$/g, '').replace(/`[^`]*`/g, v => '\u0001' + (codes.push(v) - 1) + '\u0001')
    .split('|').map(v => v.trim().replace(/\u0001(\d+)\u0001/g, (_, i) => codes[Number(i)]));
};
function renderMarkdown(body, section) {
  const lines = body.trim().split('\n');
  let out = '', sub = 0;
  for (let i = 0; i < lines.length;) {
    const line = lines[i];
    if (!line.trim()) { i++; continue; }
    if (line.startsWith('```')) {
      const lang = line.slice(3).trim();
      const code = [];
      for (++i; i < lines.length && !lines[i].startsWith('```'); i++) code.push(lines[i]);
      if (i === lines.length) throw new Error('Unclosed code fence: ' + section.file);
      i++; out += codeBlock(code.join('\n'), lang); continue;
    }
    const heading = line.match(/^(#{3,4}) (.+)$/);
    if (heading) {
      const level = heading[1].length;
      const id = section.id + '-s' + (++sub);
      out += '<h' + level + ' id="' + id + '">' + inline(heading[2]) + '<a class="anchor" href="#' + id + '" aria-label="この項目へのリンク">#</a></h' + level + '>';
      i++; continue;
    }
    if (line.startsWith('|') && /^\|[\s:|\-]+\|\s*$/.test(lines[i + 1] || '')) {
      const head = cells(line);
      out += '<div class="table-wrap" role="region" aria-label="' + esc(section.title) + 'の一覧表" tabindex="0"><table><thead><tr>' + head.map(v => '<th scope="col">' + inline(v) + '</th>').join('') + '</tr></thead><tbody>';
      i += 2;
      while (i < lines.length && lines[i].startsWith('|')) {
        const row = cells(lines[i++]);
        if (row.length !== head.length) throw new Error('Table column mismatch in ' + section.file + ': ' + row.join(' / '));
        out += '<tr>' + row.map(v => '<td>' + inline(v) + '</td>').join('') + '</tr>';
      }
      out += '</tbody></table></div>'; continue;
    }
    if (/^(?:- |\d+\. )/.test(line)) {
      const ordered = /^\d/.test(line), tag = ordered ? 'ol' : 'ul';
      const pattern = ordered ? /^\d+\. / : /^- /;
      out += '<' + tag + '>';
      while (i < lines.length && pattern.test(lines[i])) {
        out += '<li>' + inline(lines[i++].replace(pattern, '')) + '</li>';
      }
      out += '</' + tag + '>'; continue;
    }
    const paragraph = [line];
    i++;
    while (i < lines.length && lines[i].trim() && !/^(?:```|#{3,4} |\||- |\d+\. )/.test(lines[i])) paragraph.push(lines[i++]);
    out += '<p>' + inline(paragraph.join('\n')) + '</p>';
  }
  return out;
}
const articles = allSections.map((s, i) => '<section class="chapter" id="' + s.id + '" data-group="' + esc(s.group) + '" aria-labelledby="' + s.id + '-title"><div class="chapter-meta"><span>CHAPTER ' + String(i + 1).padStart(2, '0') + ' / ' + esc(s.group) + '</span><a href="' + s.file + '">原稿 ↗</a></div><h2 id="' + s.id + '-title">' + esc(s.title) + '<a class="anchor" href="#' + s.id + '" aria-label="この章へのリンク">#</a></h2>' + renderMarkdown(s.body, s) + '</section>').join('\n');
const navigation = groups.map(g => '<div class="nav-group"><p>' + g.title + '</p>' + g.sections.map(s => '<a href="#' + s.id + '">' + esc(s.title.replace('標準関数の詳細：', '')) + '</a>').join('') + '</div>').join('');

const css = String.raw`
:root{color-scheme:light;--bg:#f9faf7;--surface:#fff;--text:#23362f;--muted:#62736b;--border:#dbe3dc;--accent:#226748;--soft:#eaf3eb;--code:#f0f4ef;--kw:#8058a0;--str:#216d4b;--num:#a55222;--shadow:0 20px 70px #17332625}
:root[data-theme=dark]{color-scheme:dark;--bg:#121a17;--surface:#1a2420;--text:#e0eae2;--muted:#a0b4a7;--border:#33443a;--accent:#91d4ad;--soft:#213c2b;--code:#18271f;--kw:#d5b0f0;--str:#94d5a4;--num:#efbc8c;--shadow:0 20px 70px #0007}
*{box-sizing:border-box}html{scroll-padding-top:95px;scroll-behavior:smooth}body{margin:0;background:var(--bg);color:var(--text);font:15px/1.95 -apple-system,BlinkMacSystemFont,"Segoe UI","Yu Gothic UI","Meiryo",sans-serif;letter-spacing:.015em}button,input{font:inherit}button,a,input{-webkit-tap-highlight-color:transparent}button{cursor:pointer}a{color:var(--accent);text-underline-offset:4px}button:focus-visible,a:focus-visible,input:focus-visible,pre:focus-visible,.table-wrap:focus-visible{outline:3px solid var(--accent);outline-offset:4px}button{color:var(--text)}.skip{position:fixed;top:-100px;left:16px;background:var(--surface);padding:12px;z-index:100}.skip:focus{top:10px}.sidebar{position:fixed;inset:0 auto 0 0;width:276px;z-index:25;background:var(--surface);border-right:1px solid var(--border);display:flex;flex-direction:column}.brand{display:flex;align-items:center;gap:12px;padding:27px 25px 20px;text-decoration:none;color:var(--text)}.brand-mark{display:grid;place-items:center;border:1px solid var(--accent);border-radius:13px;width:39px;height:43px;font:700 25px Georgia,serif;color:var(--accent)}.brand strong{font:700 27px Georgia,serif;letter-spacing:-1px}.brand small{display:block;font-size:10px;color:var(--muted);letter-spacing:.12em;line-height:1.5}.search-open{margin:0 20px 20px;background:var(--bg);border:1px solid var(--border);border-radius:8px;text-align:left;padding:9px 11px;color:var(--muted);font-size:13px;display:flex;gap:12px;align-items:center;justify-content:space-between}kbd{font:11px/1.5 ui-monospace,Consolas,monospace;border:1px solid var(--border);padding:1px 5px;border-radius:4px}.nav-scroll{overflow:auto;padding:0 17px 22px;flex:1;scrollbar-width:thin}.nav-group{margin:0 0 21px}.nav-group p{font-size:10px;font-weight:700;letter-spacing:.16em;color:var(--muted);padding:0 10px;margin:0 0 8px}.nav-group a{display:block;padding:5px 11px;border-radius:6px;text-decoration:none;color:var(--muted);font-size:12px;line-height:1.75;margin:2px 0;overflow-wrap:anywhere}.nav-group a:hover{background:var(--bg);color:var(--accent)}.nav-group a[aria-current=true]{background:var(--soft);color:var(--accent);font-weight:700;box-shadow:inset 3px 0 var(--accent)}.sidebar-footer{padding:13px 26px;border-top:1px solid var(--border);font-size:10px;color:var(--muted);letter-spacing:.08em}.layout{margin-left:276px}.topbar{position:sticky;top:0;height:66px;z-index:20;display:flex;align-items:center;justify-content:space-between;padding:0 42px;border-bottom:1px solid var(--border);background:var(--bg);gap:15px}.crumb{color:var(--muted);font-size:12px}.crumb span{color:var(--accent);margin-right:13px}.actions{display:flex;gap:8px}.toolbar-button{background:var(--surface);border:1px solid var(--border);border-radius:7px;padding:5px 11px;font-size:12px;white-space:nowrap}.menu-toggle{display:none}.progress{position:fixed;top:0;left:276px;right:0;height:3px;z-index:30;pointer-events:none}.progress div{height:100%;width:0;background:var(--accent)}main{max-width:1050px;margin:auto;padding:54px 56px 80px}.eyebrow{font:11px/1.6 ui-monospace,Consolas,monospace;color:var(--accent);letter-spacing:.17em;display:flex;align-items:center;gap:9px}.eyebrow:before{content:"";width:7px;height:7px;border-radius:50%;background:var(--accent)}.hero{padding:0 0 38px}.hero-grid{display:grid;grid-template-columns:1.15fr 1fr;gap:32px;align-items:center}.hero h1{font-size:43px;line-height:1.4;letter-spacing:-.04em;margin:16px 0 19px;font-weight:700}.hero h1 em{font-family:Georgia,serif;font-size:70px;font-style:normal;font-weight:500;letter-spacing:-3px}.lead{color:var(--muted);font-size:14px;line-height:2;max-width:490px}.hero-sample{background:var(--soft);border:1px solid var(--border);border-radius:11px;overflow:hidden;transform:rotate(1deg)}.hero-sample .sample-label{font:10px ui-monospace,monospace;letter-spacing:.1em;padding:13px 18px;border-bottom:1px solid var(--border);color:var(--muted)}.hero-sample pre{padding:21px 18px;font-size:12px;line-height:2;overflow:auto;margin:0}.hero-links{display:flex;gap:11px;flex-wrap:wrap;margin-top:26px}.pill-link{display:inline-block;border:1px solid var(--border);padding:7px 15px;border-radius:7px;font-size:12px;text-decoration:none;background:var(--surface)}.pill-link.primary{background:var(--accent);color:var(--bg);border-color:var(--accent)}.stats{display:grid;grid-template-columns:repeat(3,1fr);gap:14px;margin:35px 0 22px}.stat{border-top:1px solid var(--border);padding:16px 0}.stat strong{font:500 27px Georgia,serif;color:var(--accent);margin-right:9px}.stat span{font-size:11px;color:var(--muted)}.note{border-left:3px solid var(--accent);padding:12px 17px;background:var(--soft);border-radius:0 6px 6px 0;font-size:12px;color:var(--muted)}.chapter{padding:43px 0 48px;border-top:1px solid var(--border);scroll-margin-top:20px}.chapter-meta{display:flex;justify-content:space-between;gap:12px;color:var(--muted);font-size:10px;letter-spacing:.12em}.chapter-meta a{white-space:nowrap;text-decoration:none;letter-spacing:0}h2{font-size:26px;line-height:1.65;letter-spacing:-.02em;margin:12px 0 24px}h3{font-size:19px;margin:37px 0 15px;line-height:1.65}h4{font-size:16px;margin:27px 0 12px}p{margin:16px 0}li{padding-left:2px;margin:7px 0}ul,ol{padding-left:24px}code,pre{font-family:"Cascadia Code","Consolas","SFMono-Regular",monospace;letter-spacing:0}p code,li code,td code,th code,h3 code{background:var(--code);padding:2px 5px;border-radius:4px;font-size:.9em;overflow-wrap:anywhere}pre code{font-size:inherit}.anchor{font-size:.72em;text-decoration:none;margin-left:10px;opacity:.35;font-weight:400}.anchor:hover,.anchor:focus{opacity:1}.code-block{margin:22px 0;border:1px solid var(--border);background:var(--code);border-radius:9px;overflow:hidden}.code-block figcaption{display:flex;justify-content:space-between;align-items:center;padding:7px 16px;border-bottom:1px solid var(--border);font:10px/1.5 ui-monospace,Consolas,monospace;color:var(--muted);letter-spacing:.08em}.copy{background:transparent;border:1px solid transparent;border-radius:5px;font:11px/1.5 inherit;color:var(--muted);padding:3px 8px}.copy:hover{border-color:var(--border);background:var(--surface)}pre{margin:0;padding:21px 22px;overflow:auto;font-size:13px;line-height:1.85;tab-size:4}.kw{color:var(--kw)}.str{color:var(--str)}.num{color:var(--num)}.comment{color:var(--muted)}.table-wrap{overflow:auto;margin:22px 0;border:1px solid var(--border);border-radius:8px}table{border-collapse:collapse;width:100%;font-size:12px;line-height:1.85;text-align:left}th{background:var(--soft);color:var(--accent);font-size:11px;font-weight:600}th,td{padding:12px 16px;border-bottom:1px solid var(--border);vertical-align:top}tr:last-child td{border-bottom:0}td:first-child{min-width:145px}tbody tr:nth-child(even){background:var(--surface)}.page-footer{padding-top:25px;border-top:1px solid var(--border);display:flex;justify-content:space-between;gap:20px;font-size:11px;color:var(--muted)}dialog{padding:0;background:var(--surface);color:var(--text);border:1px solid var(--border);border-radius:13px;width:min(730px,calc(100% - 28px));max-height:80vh;box-shadow:var(--shadow);margin:10vh auto}dialog::backdrop{background:#12241c80;backdrop-filter:blur(3px)}.search-head{padding:18px 22px;display:flex;align-items:center;justify-content:space-between;border-bottom:1px solid var(--border)}.search-head label{font-size:13px;font-weight:700}.search-field{margin:17px 22px 5px;display:block;width:calc(100% - 44px);background:var(--bg);border:1px solid var(--border);border-radius:7px;padding:11px 13px;color:var(--text);font-size:16px}.search-status{font-size:12px;color:var(--muted);margin:8px 23px 12px}.search-results{overflow:auto;max-height:49vh;padding:0 12px 16px}.result{display:block;padding:13px 12px;text-decoration:none;border-top:1px solid var(--border);border-radius:5px}.result:hover,.result:focus{background:var(--soft)}.result strong{display:block;font-size:14px}.result small{display:block;color:var(--muted);font-size:10px;margin-bottom:3px}.result p{font-size:12px;color:var(--muted);margin:5px 0 0;line-height:1.8;overflow-wrap:anywhere}mark{background:#f1dc94;color:#27352c;border-radius:2px}.toast{position:fixed;bottom:25px;left:50%;transform:translateX(-50%);z-index:60;background:var(--text);color:var(--bg);border-radius:8px;padding:10px 18px;font-size:12px;box-shadow:var(--shadow)}.toast:empty{display:none}.scrim{display:none}[hidden]{display:none!important}
@media(min-width:1500px){main{max-width:1140px;padding-left:70px;padding-right:70px}.hero h1{font-size:47px}}
@media(max-width:1120px){.hero-grid{grid-template-columns:1fr}.hero-sample{max-width:600px;transform:none}.hero h1 br{display:none}.hero h1 em{margin-right:15px}.hero h1{font-size:35px}.hero h1 em{font-size:58px}main{padding:40px 35px}.topbar{padding:0 30px}}
@media(max-width:780px){.sidebar{transform:translateX(-100%);transition:transform .18s}.sidebar.open{transform:translateX(0)}.scrim.visible{display:block;position:fixed;inset:0;z-index:24;background:#12241c88}.layout{margin-left:0}.progress{left:0}.menu-toggle{display:block}.topbar{padding:0 18px;height:59px}.crumb{flex:1;font-size:11px}.crumb span{display:none}.actions{gap:5px}.toolbar-button{padding:5px 8px;font-size:11px}main{padding:31px 22px 55px}.hero h1{font-size:28px}.hero h1 br{display:block}.hero h1 em{font-size:61px}.hero-grid{gap:20px}.stats{gap:9px;margin-top:25px}.stat strong{display:block}.stat span{font-size:10px}h2{font-size:23px}h3{font-size:18px}.chapter{padding:31px 0}.chapter-meta{font-size:9px}body{font-size:14px}pre{font-size:12px;padding:16px}th,td{padding:10px 12px}.page-footer{flex-direction:column}.hero-sample pre{font-size:11px}.print-button{display:none}}
@media(prefers-reduced-motion:reduce){html{scroll-behavior:auto}*{transition:none!important}}
@media print{:root,:root[data-theme=dark]{--bg:#fff;--surface:#fff;--text:#111;--muted:#444;--border:#ccc;--accent:#174b32;--soft:#f2f5f2;--code:#f5f5f5;--kw:#553277;--str:#24552f;--num:#813e16;color-scheme:light}.sidebar,.topbar,.progress,.copy,.anchor,.hero-links,.chapter-meta a,dialog,.toast,.scrim,.skip{display:none!important}.layout{margin:0}main{max-width:none;padding:0}.hero{padding-bottom:15px}.hero-grid{display:block}.hero-sample{display:none}.stats{margin:10px 0}.chapter{padding:20px 0;break-before:auto}.chapter-meta{font-size:8pt}h2,h3,h4{break-after:avoid}pre{white-space:pre-wrap;overflow-wrap:anywhere;font-size:8pt}.code-block{break-inside:avoid}body{font-size:9pt;line-height:1.7}table{font-size:8pt}.table-wrap{overflow:visible}tr{break-inside:avoid}a{color:inherit;text-decoration:none}@page{margin:16mm}}
`;
const js = String.raw`
(() => {
  const $ = s => document.querySelector(s);
  const sidebar = $('.sidebar'), menu = $('.menu-toggle'), scrim = $('.scrim');
  function closeMenu(){sidebar.classList.remove('open');scrim.classList.remove('visible');menu.setAttribute('aria-expanded','false');sidebar.inert=innerWidth<=780;if(sidebar.inert&&sidebar.contains(document.activeElement))menu.focus();}
  function toggleMenu(){const open=!sidebar.classList.contains('open');closeMenu();if(open){sidebar.inert=false;sidebar.classList.add('open');scrim.classList.add('visible');menu.setAttribute('aria-expanded','true');$('.search-open').focus();}}
  closeMenu();
  menu.addEventListener('click',toggleMenu);scrim.addEventListener('click',closeMenu);
  sidebar.addEventListener('click',e=>{if(e.target.closest('a'))closeMenu();});
  const media=matchMedia('(prefers-color-scheme: dark)');
  const themeButton=$('#theme');
  function setTheme(theme){document.documentElement.dataset.theme=theme;themeButton.textContent=theme==='dark'?'ライト':'ダーク';themeButton.setAttribute('aria-label',(theme==='dark'?'ライト':'ダーク')+'テーマに切り替え');}
  let saved;try{saved=localStorage.getItem('dua-reference-theme');}catch{}
  setTheme(saved==='light'||saved==='dark'?saved:media.matches?'dark':'light');
  themeButton.addEventListener('click',()=>{const next=document.documentElement.dataset.theme==='dark'?'light':'dark';setTheme(next);try{localStorage.setItem('dua-reference-theme',next);}catch{}});
  $('.print-button').addEventListener('click',()=>window.print());
  const notice=$('.toast');let noticeTimer;
  function toast(text){clearTimeout(noticeTimer);notice.textContent=text;noticeTimer=setTimeout(()=>notice.textContent='',2300);}
  document.addEventListener('click',async e=>{
    const button=e.target.closest('.copy');if(!button)return;
    const code=button.closest('figure').querySelector('pre code').textContent;
    let ok=false;
    try{await navigator.clipboard.writeText(code);ok=true;}catch{
      const area=document.createElement('textarea');area.value=code;area.style.cssText='position:fixed;left:-9999px;top:0';document.body.append(area);area.select();try{ok=document.execCommand('copy');}catch{}area.remove();button.focus();
    }
    if(ok){button.textContent='コピー済み';toast('コードをコピーしました');setTimeout(()=>button.textContent='コピー',1700);}
    else{const range=document.createRange();range.selectNodeContents(button.closest('figure').querySelector('pre code'));const selection=window.getSelection();selection.removeAllRanges();selection.addRange(range);toast('コードを選択しました。Ctrl+C でコピーできます');}
  });
  const dialog=$('#search-dialog'),input=$('#search-input'),results=$('.search-results'),status=$('.search-status');
  const records=[];
  document.querySelectorAll('.chapter').forEach(section=>{
    const title=section.querySelector('h2').textContent.replace(/#$/,'');
    let record={id:section.id,title,group:section.dataset.group,text:''};records.push(record);
    Array.from(section.children).forEach(node=>{
      if(/^H[34]$/.test(node.tagName)){record={id:node.id,title:node.textContent.replace(/#$/,''),group:section.dataset.group+' / '+title,text:''};records.push(record);}
      else if(!node.matches('.chapter-meta,h2'))record.text+=' '+node.textContent;
    });
  });
  function marked(target,text,terms){
    const lower=text.toLocaleLowerCase();let cursor=0;
    while(cursor<text.length){let start=-1,term='';for(const candidate of terms){const pos=lower.indexOf(candidate,cursor);if(pos>=0&&(start<0||pos<start)){start=pos;term=candidate;}}
      if(start<0){target.append(document.createTextNode(text.slice(cursor)));break;}
      target.append(document.createTextNode(text.slice(cursor,start)));const mark=document.createElement('mark');mark.textContent=text.slice(start,start+term.length);target.append(mark);cursor=start+term.length;
    }
  }
  function search(){
    results.replaceChildren();const terms=input.value.trim().toLocaleLowerCase().split(/\s+/).filter(Boolean);
    if(!terms.length){status.textContent='構文・関数名・日本語の説明から検索できます。空白区切りで絞り込み。';return;}
    const hits=records.filter(r=>terms.every(t=>(r.title+' '+r.text).toLocaleLowerCase().includes(t))).sort((a,b)=>terms.filter(t=>b.title.toLocaleLowerCase().includes(t)).length-terms.filter(t=>a.title.toLocaleLowerCase().includes(t)).length);
    status.textContent=hits.length?hits.length+' 件の項目が見つかりました'+(hits.length>40?'（先頭40件を表示）':''):'見つかりませんでした。短い語句や別の表記で検索してください。';
    hits.slice(0,40).forEach(r=>{const link=document.createElement('a');link.className='result';link.href='#'+r.id;
      const group=document.createElement('small');group.textContent=r.group;const title=document.createElement('strong');marked(title,r.title,terms);
      const excerpt=document.createElement('p');const text=r.text.replace(/\s+/g,' ').trim();const pos=text.toLocaleLowerCase().indexOf(terms[0]);const start=Math.max(0,pos-32);marked(excerpt,(start?'…':'')+text.slice(start,start+140)+(start+140<text.length?'…':''),terms);
      link.append(group,title,excerpt);link.addEventListener('click',()=>{dialog.close();closeMenu();requestAnimationFrame(()=>{const target=document.getElementById(r.id);target.setAttribute('tabindex','-1');target.focus({preventScroll:true});target.scrollIntoView({block:'start'});});});results.append(link);
    });
  }
  function openSearch(){closeMenu();dialog.showModal();search();input.focus();input.select();}
  $('.search-open').addEventListener('click',openSearch);$('#mobile-search').addEventListener('click',openSearch);$('#search-close').addEventListener('click',()=>dialog.close());input.addEventListener('input',search);
  dialog.addEventListener('click',e=>{if(e.target===dialog){const r=dialog.getBoundingClientRect();if(e.clientX<r.left||e.clientX>r.right||e.clientY<r.top||e.clientY>r.bottom)dialog.close();}});
  input.addEventListener('keydown',e=>{if(e.key==='ArrowDown'){e.preventDefault();results.querySelector('a')?.focus();}if(e.key==='Enter')results.querySelector('a')?.click();});
  document.addEventListener('keydown',e=>{
    const editing=/INPUT|TEXTAREA|SELECT/.test(document.activeElement.tagName)||document.activeElement.isContentEditable;
    if((e.key==='/'&&!editing)||((e.ctrlKey||e.metaKey)&&e.key.toLowerCase()==='k')){e.preventDefault();if(!dialog.open)openSearch();}
    if(e.key==='Escape'&&!dialog.open){closeMenu();}
  });
  const chapters=Array.from(document.querySelectorAll('.chapter')),navLinks=Array.from(document.querySelectorAll('.nav-group a'));
  let pending=false,lastId='';
  function updateScroll(){pending=false;const max=document.documentElement.scrollHeight-innerHeight;$('.progress div').style.width=(max>0?Math.min(100,scrollY/max*100):0)+'%';let active=chapters[0];for(const section of chapters){if(section.getBoundingClientRect().top<=140)active=section;else break;}
    if(lastId!==active.id){lastId=active.id;navLinks.forEach(link=>{if(link.hash==='#'+active.id)link.setAttribute('aria-current','true');else link.removeAttribute('aria-current');});$('#current-group').textContent=active.dataset.group;}
  }
  addEventListener('scroll',()=>{if(!pending){pending=true;requestAnimationFrame(updateScroll);}},{passive:true});addEventListener('resize',()=>{closeMenu();updateScroll();});updateScroll();
})();
`;
const sample = 'table Player {\n    string name;\n    int hp;\n}\n\nPlayer hero = { name = "Ada", hp = 100 };\nreturn i"Hello, $(hero.name).";';
const html = `<!doctype html>
<html lang="ja"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="description" content="Dua言語の日本語リファレンス。構文、型、標準ライブラリ、Dへの組み込みAPI、実用例を検索できるオフライン対応の解説書。"><meta name="color-scheme" content="light dark"><title>Dua 言語リファレンス — 構文・標準ライブラリ・D API</title><style>${css}</style></head>
<body><a class="skip" href="#content">本文へスキップ</a><div class="progress" aria-hidden="true"><div></div></div>
<aside class="sidebar" id="sidebar" aria-label="リファレンス目次"><a class="brand" href="#top"><span class="brand-mark" aria-hidden="true">d</span><span><strong>Dua</strong><small>LANGUAGE REFERENCE</small></span></a><button class="search-open" type="button" aria-haspopup="dialog" aria-controls="search-dialog"><span>⌕ リファレンスを検索</span><kbd>/</kbd></button><nav class="nav-scroll" aria-label="章の一覧">${navigation}</nav><div class="sidebar-footer">日本語 · オフライン対応 · 実装準拠</div></aside>
<div class="scrim" aria-hidden="true"></div><div class="layout"><header class="topbar"><button type="button" class="toolbar-button menu-toggle" aria-label="目次を開閉" aria-controls="sidebar" aria-expanded="false">目次</button><div class="crumb"><span>Documentation /</span><b id="current-group">はじめに</b></div><div class="actions"><button id="mobile-search" type="button" class="toolbar-button" aria-haspopup="dialog" aria-controls="search-dialog">検索</button><button id="theme" type="button" class="toolbar-button">ダーク</button><button type="button" class="toolbar-button print-button">印刷 / PDF</button></div></header>
<main id="content"><div class="hero" id="top"><div class="eyebrow">THE DUA LANGUAGE / REFERENCE BOOK</div><div class="hero-grid"><div><h1><em>Dua</em><br>言語リファレンス</h1><p class="lead">小さなスクリプトから、D アプリケーションの拡張まで。構文・型・標準ライブラリ・ホスト連携を、動作の違いと具体例から理解するための一冊。</p><div class="hero-links"><a class="pill-link primary" href="#guide-1">最初のプログラム →</a><a class="pill-link" href="#guide-2">標準関数を探す</a><a class="pill-link" href="#host-1">D API を読む</a></div></div><div class="hero-sample"><div class="sample-label">HELLO, DUA / example.dua</div><pre><code>${highlight(sample)}</code></pre></div></div><div class="stats"><div class="stat"><strong>${allSections.length}</strong><span>の章で体系的に解説</span></div><div class="stat"><strong>${codeCount}</strong><span>のコードブロック</span></div><div class="stat"><strong>Offline</strong><span>単体 HTML・外部依存なし</span></div></div><div class="note">このリポジトリの実装を基準にした日本語版です。検索は <kbd>/</kbd> または <kbd>Ctrl K</kbd>。Dua とホスト側 D のコードをラベルで区別しています。</div><noscript><p class="note">JavaScriptが無効です。目次・本文・ブラウザーのページ内検索は利用できます。独自検索・コピー・テーマ切り替えにはJavaScriptが必要です。</p></noscript></div>
${articles}<footer class="page-footer"><span>Dua / 日本語リファレンス · リポジトリ同梱版</span><a href="#top">ページの先頭へ ↑</a></footer></main></div>
<dialog id="search-dialog" aria-labelledby="search-label"><div class="search-head"><label id="search-label" for="search-input">リファレンスを検索</label><button type="button" id="search-close" class="toolbar-button" aria-label="検索を閉じる">閉じる / Esc</button></div><input id="search-input" class="search-field" type="search" placeholder="例：cast、コピー、coroutine、bindNative" autocomplete="off" spellcheck="false"><p class="search-status" role="status" aria-live="polite"></p><div class="search-results" aria-label="検索結果"></div></dialog><div class="toast" role="status" aria-live="polite"></div><script>${js}</script></body></html>
`;
const ids = [...html.matchAll(/\bid="([^"]+)"/g)].map(m => m[1]);
if (new Set(ids).size !== ids.length) throw new Error('Duplicate HTML id');
for (const [, anchor] of html.matchAll(/href="#([^"]+)"/g)) if (!ids.includes(anchor)) throw new Error('Broken anchor: ' + anchor);
writeFileSync(join(dir, 'language-reference-ja.html'), html, 'utf8');
console.log('Generated docs/language-reference-ja.html: ' + allSections.length + ' chapters, ' + codeCount + ' code blocks, ' + Buffer.byteLength(html) + ' bytes.');
