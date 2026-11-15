(function bridge(r) {
  const allowed={has:value=>{try{const u=new URL(value);return u.origin==='https://chatgpt.com' && /^\/(?:g\/[A-Za-z0-9_-]+\/)?c\/__TRANSLATEGPT_CONVERSATION_ID__\/?$/.test(u.pathname)}catch(_){return false}}};
  const profiled=r.profile==='1',timings={};
  const clock=()=>typeof performance!=='undefined'?performance.now():Date.now();
  const actionStarted=profiled?clock():0;
  const measured=(name,fn)=>{
    if(!profiled)return fn();
    const start=clock();try{return fn();}finally{timings[name]=(timings[name]||0)+clock()-start;}
  };
  const reply = x => {if(profiled){timings.action_total=clock()-actionStarted;x.timingsMs=timings;}return JSON.stringify(x);};
  if (!allowed.has(location.origin + location.pathname)) return reply({state:'wrong_page'});
  const pageURL=()=>location.origin+location.pathname;
  let savedOwner='';
  try{savedOwner=sessionStorage.getItem('TranslateGPT.engineOwner.v2')||''}catch(_){}
  if (r.owner) {
    if(!window.__TranslateGPTOwner && (savedOwner===r.owner || window.name==='TranslateGPT.engine/'+r.owner || (r.claim==='1' && !savedOwner)))window.__TranslateGPTOwner=r.owner;
    if(window.__TranslateGPTOwner!==r.owner || (savedOwner && savedOwner!==r.owner))return reply({state:'wrong_owner'});
    try{sessionStorage.setItem('TranslateGPT.engineOwner.v2',r.owner)}catch(_){}
    if(!window.name || window.name.startsWith('TranslateGPT.engine/'))window.name='TranslateGPT.engine/'+r.owner;
  }
  if(!window.__TranslateGPTDocumentID)window.__TranslateGPTDocumentID=Date.now().toString(36)+'-'+Math.random().toString(36).slice(2);
  if(r.action==='start' && r.document && r.document!==window.__TranslateGPTDocumentID)return reply({state:'document_changed',safeUnsent:true});
  window.__TranslateGPTAgentV1=bridge;
  const key='__TranslateGPTJobV1';
  const existing=window[key];
  if(r.action==='recover_status'){if(existing && existing.id===r.id && existing.owner===r.owner)return reply(existing.snapshot());return reply({state:'unknown_request',safeUnsent:!!r.document && r.document===window.__TranslateGPTDocumentID && (!existing || ['completed','stopped','failed'].includes(existing.state))});}
  if (r.action==='status' || r.action==='stop_owned' || r.action==='complete') {
    if (!existing || existing.id!==r.id || existing.owner!==r.owner) return reply({state:'unknown_request'});
    if (r.action==='stop_owned') existing.stop();
    if (r.action==='complete') existing.complete(r.expected);
    return reply(existing.snapshot());
  }
  if (r.action==='start') {
    if (existing && existing.id===r.id) return reply(existing.snapshot());
    if (existing && existing.settle) existing.settle();
    if (existing && !['completed','stopped','failed'].includes(existing.state)) return reply({state:'occupied',safeUnsent:true});
    const job={started:clock(),prepareMs:0,readyWaitMs:0,sendMs:0,sentAt:null,lastActiveAt:null,failure:null,id:r.id,owner:r.owner,state:'preparing',text:'',generating:false,sent:false,firstOutputAt:null,deadline:clock()+4000};
    window[key]=job;
    let observer,answer=null,user=null,semanticAnswer=false,scheduled=false,checking=false;
    const valid=()=>allowed.has(pageURL()) && (!r.owner || window.__TranslateGPTOwner===r.owner) && window[key]===job;
    const invoke=action=>JSON.parse(bridge({...r,action}));
    const normalized=t=>t.replace(/\s+/g,' ').trim();
    const requestText=e=>{const text=e.innerText,index=text.indexOf('Request ID: '+r.id);return index>=0 ? normalized(text.slice(index)) : '';};
    const semanticUsers=()=>Array.from(document.querySelectorAll('h4')).filter(e=>e.innerText.trim()==='You said:').map(e=>e.parentElement);
    // Rebuild the rendered reply as Markdown so paragraphs, lists, headings, emphasis and code survive.
    // Reads only the matched reply; skips controls, hidden and screen-reader-only text. Callers fall back to innerText.
    const markdownOf=root=>{
      const cls=(e,c)=>!!(e.classList && e.classList.contains && e.classList.contains(c));
      const skip=e=>/^(BUTTON|SVG|STYLE|SCRIPT|TEMPLATE|NOSCRIPT|IMG)$/.test(e.tagName) || e.hidden===true || cls(e,'sr-only')
        || (e.getAttribute && e.getAttribute('aria-hidden')==='true') || (e.tagName==='H4' && /^(You said:|ChatGPT said:)$/.test((e.textContent||'').trim()));
      const isBlock=e=>/^(P|DIV|SECTION|ARTICLE|UL|OL|LI|H[1-6]|PRE|BLOCKQUOTE|TABLE|THEAD|TBODY|TR|HR)$/.test(e.tagName);
      const inline=n=>{
        if(n.nodeType===3)return (n.nodeValue||'').replace(/\s+/g,' ');
        if(n.nodeType!==1 || skip(n))return '';
        if(cls(n,'katex-display')){const tex=n.querySelector && n.querySelector('annotation');if(tex)return '$$'+tex.textContent+'$$';}
        if(cls(n,'katex')){const tex=n.querySelector && n.querySelector('annotation');return tex ? '$'+tex.textContent+'$' : (n.textContent||'');}
        if(n.tagName==='BR')return '\n';
        if(n.tagName==='CODE')return '`'+(n.textContent||'')+'`';
        const inner=Array.from(n.childNodes||[]).map(inline).join('');
        if(!inner.trim())return inner;
        if(n.tagName==='STRONG' || n.tagName==='B')return '**'+inner.trim()+'**';
        if(n.tagName==='EM' || n.tagName==='I')return '*'+inner.trim()+'*';
        return inner;
      };
      const blocks=[];
      const walk=(node,ctx)=>{
        let para='';
        const emit=(text,tight)=>{
          const pad=ctx.marker ? ' '.repeat(ctx.marker.length) : '';
          const lead=ctx.indent+(ctx.marker && !ctx.used ? ctx.marker : pad);ctx.used=true;
          blocks.push({text:lead+text.replace(/\n/g,'\n'+ctx.indent+pad),tight:tight || !!ctx.marker});
        };
        const flush=()=>{const s=para.replace(/[ \t]*\n[ \t]*/g,'\n').trim();para='';if(s)emit(s);};
        for(const c of Array.from(node.childNodes||[])){
          if(c.nodeType===1 && skip(c))continue;
          if(c.nodeType!==1 || !isBlock(c)){para+=inline(c);continue;}
          flush();
          const t=c.tagName,inner=ctx.indent+(ctx.marker ? ' '.repeat(ctx.marker.length) : '');
          if(t==='UL' || t==='OL'){let k=0;for(const li of Array.from(c.children||[])){if(li.tagName!=='LI')continue;k++;walk(li,{indent:inner,marker:t==='OL' ? k+'. ':'- ',used:false});}}
          else if(/^H[1-6]$/.test(t)){const s=inline(c).trim();if(s)emit('#'.repeat(+t[1])+' '+s);}
          else if(t==='PRE'){const code=(c.querySelector && c.querySelector('code')) || c,lang=((code.getAttribute && code.getAttribute('class'))||'').match(/language-([\w+-]+)/);emit('```'+(lang ? lang[1]:'')+'\n'+(code.textContent||'').replace(/\n$/,'')+'\n```');}
          else if(t==='BLOCKQUOTE'){const start=blocks.length;walk(c,ctx);for(let i=start;i<blocks.length;i++)blocks[i].text='> '+blocks[i].text.replace(/\n/g,'\n> ');}
          else if(t==='HR')emit('---');
          else if(t==='TR')emit('| '+Array.from(c.children||[]).map(cell=>inline(cell).trim()).join(' | ')+' |',true);
          else walk(c,ctx);
        }
        flush();
      };
      walk(root,{indent:'',marker:null,used:false});
      return blocks.map((b,i)=>(i===0 ? '' : (blocks[i-1].tight && b.tight ? '\n':'\n\n'))+b.text).join('').trim();
    };
    const replyText=e=>{let md='';try{md=markdownOf(e);}catch(_){}return md || (semanticAnswer ? e.innerText.replace(/^\s*ChatGPT said:\s*/,'').trim() : e.innerText.trim());};
    job.snapshot=()=>{if(['preparing','waitingReady'].includes(job.state) && clock()>job.deadline){invoke('cancel_prepared');finish('failed');}job.settle();return ({state:job.state,failure:job.failure,text:job.text,generating:job.generating,safeUnsent:!job.sent,firstOutputAt:job.firstOutputAt,pageNow:clock(),prepareMs:job.prepareMs,readyWaitMs:job.readyWaitMs,sendMs:job.sendMs,sentAt:job.sentAt,completionEvidence:!!job.completionEvidence,stopReason:job.stopReason||null,submittedMatches:!!job.submittedMatches,submissionCount:job.submissionCount||0,owned:true});};
    const finish=state=>{job.state=state;observer.disconnect();};
    const changed=()=>{
      if (checking || !valid()) {if(!valid()) finish('failed');return;}
      checking=true;
      try {
        if (['preparing','waitingReady'].includes(job.state)) {
          if(clock()>job.deadline){finish('failed');return;}
          const readiness=invoke('ready');
          if(readiness.state==='draft_mismatch' || readiness.state==='mode_changed') {finish('failed');return;}
          if(readiness.state!=='ready')return;
          job.readyWaitMs=clock()-job.started-job.prepareMs;job.state='sending';job.sent=true; // protect against ambiguous click acknowledgement
          job.sentAt=clock();const result=invoke('send');job.sendMs=clock()-job.sentAt;
          if(result.state!=='send_attempted'){job.sent=false;finish('failed');return;}
          job.state='sent';
        }
        if(!job.sent)return;
        if(!answer || !answer.isConnected) {
          const nodes=Array.from(document.querySelectorAll('[data-message-author-role]'));
          const matching=nodes.filter(e=>e.getAttribute('data-message-author-role')==='user' && e.innerText.includes(r.id));
          const i=nodes.indexOf(matching[0]);
          if(i>=0){user=nodes[i];job.submissionCount=matching.length;const next=nodes[i+1];if(next && next.getAttribute('data-message-author-role')==='assistant')answer=next;}
          else {
            const headings=Array.from(document.querySelectorAll('h4')).filter(e=>['You said:','ChatGPT said:'].includes(e.innerText.trim()));
            const index=headings.findIndex(e=>e.innerText.trim()==='You said:' && e.parentElement.innerText.includes(r.id));
            if(index>=0){user=headings[index].parentElement;job.submissionCount=semanticUsers().filter(e=>e.innerText.includes(r.id)).length;const next=headings[index+1];if(next && next.innerText.trim()==='ChatGPT said:'){answer=next.parentElement;semanticAnswer=true;}}
          }
          if(user)job.submittedMatches=requestText(user)===normalized(r.prompt);
        }
        const output=answer ? replyText(answer) : '';
        const active=Array.from(document.querySelectorAll('button[data-testid="stop-button"],button[aria-label="Stop"],button[aria-label="Stop generating"],button[aria-label="Stop streaming"]')).some(e=>e.getClientRects().length>0 && getComputedStyle(e).visibility!=='hidden');
        job.generating=active;
        if(active){job.sawGeneration=true;job.lastActiveAt=clock();}
        const turn=answer && answer.closest ? answer.closest('[data-testid^="conversation-turn-"]') : null;
        const copy=turn ? Array.from(turn.querySelectorAll('button[data-testid="copy-turn-action-button"]')).filter(e=>e.getClientRects().length>0 && getComputedStyle(e).visibility!=='hidden' && !e.disabled) : [];
        job.completionEvidence=!!(job.sawGeneration && output && !active && copy.length===1);
        if(output){if(job.firstOutputAt===null)job.firstOutputAt=clock();job.text=output;if(job.state!=='stopping')job.state='responding';}
        if(job.state==='stopping' && !active)finish('stopped');
      } finally {checking=false;}
    };
    job.complete=expected=>{changed();if(valid() && job.text && !job.generating && job.text===expected)finish('completed');};
    job.stop=()=>{
      if(!valid())return;
      if(!job.sent){invoke('cancel_prepared');finish('stopped');return;}
      changed();
      // Refuse Stop if the newest user message cannot be positively matched.
      let users=Array.from(document.querySelectorAll('[data-message-author-role="user"]'));
      if(!users.length)users=semanticUsers();
      const newest=users[users.length-1];
      const stops=Array.from(document.querySelectorAll('button[data-testid="stop-button"],button[aria-label="Stop"],button[aria-label="Stop generating"],button[aria-label="Stop streaming"]')).filter(e=>e.getClientRects().length>0 && getComputedStyle(e).visibility!=='hidden');
      if(!newest || !newest.innerText.includes(r.id) || users.filter(e=>e.innerText.includes(r.id)).length!==1 || requestText(newest)!==normalized(r.prompt)){job.stopReason='request_not_matched';return;}
      if(!stops.length && job.text){finish('stopped');return;}
      if(stops.length!==1){job.stopReason='stop_controls_'+stops.length;return;}
      if(job.state!=='stopping'){job.stopReason='clicked';job.state='stopping';stops[0].click();}
      changed();
    };
    // A submitted job with no output and no visible generation for 20 s is finished: nothing is
    // running for it. Mark it failed so it cannot block later explicit requests. Never resend it.
    job.settle=()=>{
      if(job.state!=='sent' || job.text || clock()-Math.max(job.sentAt||job.started,job.lastActiveAt||0)<20000)return;
      changed();
      if(job.state!=='sent' || job.text)return;
      if(job.generating){job.lastActiveAt=clock();return;}
      // Send was not accepted only if our exact prompt is still the draft; cancel_prepared removes nothing else.
      job.failure=!user && invoke('cancel_prepared').state==='cancelled' ? 'send_not_accepted':'no_response';
      finish('failed');
    };
    observer=new MutationObserver(()=>{if(!scheduled){scheduled=true;queueMicrotask(()=>{scheduled=false;changed();});}});
    observer.observe(document.documentElement,{subtree:true,childList:true,characterData:true,attributes:true,attributeFilter:['disabled','aria-disabled','data-state']});
    const preparation=invoke('prepare');job.prepareMs=clock()-job.started;
    if(preparation.state!=='prepared'){finish('failed');return reply(job.snapshot());}
    job.state='waitingReady';changed();
    // Deadline also prevents a delayed background-tab observer from sending much later.
    setTimeout(()=>{if(['preparing','waitingReady'].includes(job.state)){invoke('cancel_prepared');finish('failed');}},4000);
    return reply(job.snapshot());
  }
  const visible = e => e.getClientRects().length > 0 && getComputedStyle(e).visibility !== 'hidden';
  const candidates = measured('find_composer',()=>Array.from(document.querySelectorAll('#prompt-textarea,.ProseMirror[contenteditable="true"]')));
  const editable = candidates.filter(e => (e.tagName === 'TEXTAREA' || e.isContentEditable) && visible(e));
  const field = editable.length === 1 ? editable[0] : null;
  const modelButtons = measured('find_model_controls',()=>Array.from(document.querySelectorAll('button[aria-label="Select ChatGPT model"]')).filter(visible));
  // The selected mode is the control's last visible line ("Thinking effort / Instant" -> Instant). ChatGPT also has a
  // mode picker inside the message box; when present it must say Instant too, or nothing is sent.
  const modeValue = b => { const lines=(b.innerText||'').split('\n').map(t=>t.trim()).filter(Boolean); return lines.length ? lines[lines.length-1] : ''; };
  const modeWord = /^(Instant|Thinking|Auto|Pro|Heavy|Extended|Standard|Light|High|Medium|Low|Fast|Deep)\b/i;
  const composerForm = field && field.closest ? field.closest('form') : null;
  const composerPickers = measured('find_composer_mode',()=>composerForm ? Array.from(composerForm.querySelectorAll('button[aria-haspopup]'))
    .filter(b=>visible(b) && b.getAttribute('aria-label')!=='Select ChatGPT model' && modeWord.test(modeValue(b))) : []);
  const instant = () => modelButtons.length === 1 && /\bInstant\b/.test(modeValue(modelButtons[0])) && composerPickers.every(b=>/^Instant\b/i.test(modeValue(b)));
  const draft = () => field ? ('value' in field ? field.value : field.innerText).trim() : '';
  const generating = () => Array.from(document.querySelectorAll('button[data-testid="stop-button"],button[aria-label="Stop"],button[aria-label="Stop generating"],button[aria-label="Stop streaming"]')).some(visible);
  const sendControl = () => {
    const buttons=measured('find_send_control',()=>Array.from(document.querySelectorAll('button[data-testid="send-button"],button[aria-label="Send prompt"],button[aria-label="Send"]')).filter(visible));
    return buttons.length===1 ? buttons[0] : null;
  };
  if (r.action === 'inspect') return reply({state:field ? 'ready' : 'missing_composer',composerCount:editable.length,draft:!!draft(),generating:generating(),hidden:document.hidden,instant:instant(),owned:!!r.owner,document:window.__TranslateGPTDocumentID});
  if (!field) return reply({state:'missing_composer'});
  if (r.action === 'ensure_instant') {
    if (draft() || generating()) return reply({state:'occupied'});
    if (instant()) {
      if (modelButtons[0].getAttribute('aria-expanded') === 'true') modelButtons[0].click();
      return reply({state:'instant'});
    }
    if (modelButtons.length !== 1) return reply({state:'mode_unavailable'});
    // The message-box picker is left to the user: report it rather than click through an unknown menu.
    if (composerPickers.some(b=>!/^Instant\b/i.test(modeValue(b)))) return reply({state:'mode_unavailable'});
    const sliders = Array.from(document.querySelectorAll('[role="menu"] [role="slider"]')).filter(visible);
    if (sliders.length === 1 && sliders[0].getAttribute('aria-valuemin') === '0' && sliders[0].getAttribute('aria-valuemax') === '2') {
      sliders[0].focus();
      sliders[0].dispatchEvent(new KeyboardEvent('keydown',{key:'Home',code:'Home',bubbles:true,cancelable:true}));
      return reply({state:'mode_requested'});
    }
    if (modelButtons[0].getAttribute('aria-expanded') !== 'true') { modelButtons[0].click();return reply({state:'mode_menu_opened'}); }
    return reply({state:'mode_unavailable'});
  }
  if (r.action === 'prepare') {
    if (draft() || generating()) return reply({state:'occupied'});
    if (!instant()) return reply({state:'mode_changed'});
    if (modelButtons[0].getAttribute('aria-expanded') === 'true') modelButtons[0].click();
    measured('focus_composer',()=>field.focus());
    if (r.insertion==='paste' && !('value' in field)) {
      try {
        const transfer=new DataTransfer();transfer.setData('text/plain',r.prompt);
        measured('paste_dispatch',()=>field.dispatchEvent(new ClipboardEvent('paste',{clipboardData:transfer,bubbles:true,cancelable:true})));
      } catch (_) { /* fall back only while the composer is empty */ }
      if(draft() && draft()!==r.prompt)return reply({state:'input_failed'});
    }
    if ('value' in field) {
      const setter = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype,'value').set;
      measured('insert_text',()=>setter.call(field,r.prompt));
      measured('dispatch_input',()=>field.dispatchEvent(new Event('input',{bubbles:true})));
    } else if(draft()!==r.prompt) {
      measured('select_composer_contents',()=>{
        const selection = window.getSelection();
        const range = document.createRange(); range.selectNodeContents(field);
        selection.removeAllRanges(); selection.addRange(range);
      });
      if (!measured('insert_text',()=>document.execCommand('insertText',false,r.prompt))) return reply({state:'input_failed'});
    }
    window.__TranslateGPTBridgeID = r.id;
    window.__TranslateGPTBridgeStartedHidden = document.hidden;
    const send=sendControl();
    const readyForSend=instant() && draft()===r.prompt && !!send && !send.disabled && !generating();
    return reply({state:'prepared',hidden:document.hidden,readyForSend});
  }
  if (r.action === 'cancel_prepared') {
    if (window.__TranslateGPTBridgeID !== r.id || draft() !== r.prompt) return reply({state:'preserved'});
    field.focus();
    if ('value' in field) {
      Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype,'value').set.call(field,'');
      field.dispatchEvent(new Event('input',{bubbles:true}));
    } else {
      const selection=window.getSelection(); const range=document.createRange();
      range.selectNodeContents(field); selection.removeAllRanges(); selection.addRange(range);
      document.execCommand('delete',false,null);
    }
    return reply({state:draft() ? 'preserved' : 'cancelled'});
  }
  if (r.action === 'ready' || r.action === 'send') {
    if (!instant()) return reply({state:'mode_changed'});
    if (window.__TranslateGPTBridgeID !== r.id || draft() !== r.prompt) return reply({state:'draft_mismatch'});
    const send = sendControl();
    if (!send || send.disabled || generating()) return reply({state:'not_ready'});
    if (r.action === 'send') { measured('send_click',()=>send.click()); return reply({state:'send_attempted'}); }
    return reply({state:'ready'});
  }
  if (r.action === 'poll') {
    const messages = measured('find_messages',()=>Array.from(document.querySelectorAll('[data-message-author-role]')));
    const index = measured('match_request',()=>messages.findIndex(e => e.getAttribute('data-message-author-role') === 'user' && e.innerText.includes(r.id)));
    if (index >= 0) {
      const answer = messages.slice(index+1).find(e => e.getAttribute('data-message-author-role') === 'assistant');
      return reply({state:'observing',generating:generating(),text:answer ? answer.innerText.trim() : ''});
    }
    const headings = Array.from(document.querySelectorAll('h4')).filter(e => ['You said:','ChatGPT said:'].includes(e.innerText.trim()));
    const userIndex = headings.findIndex(e => e.innerText.trim() === 'You said:' && e.parentElement.innerText.includes(r.id));
    if (userIndex < 0) return reply({state:'awaiting_submission',generating:generating()});
    const next = headings[userIndex+1];
    const answer = next && next.innerText.trim() === 'ChatGPT said:' ? next.parentElement.innerText.replace(/^\s*ChatGPT said:\s*/,'').trim() : '';
    return reply({state:'observing',generating:generating(),text:answer});
  }
  return reply({state:'invalid_action'});
})
