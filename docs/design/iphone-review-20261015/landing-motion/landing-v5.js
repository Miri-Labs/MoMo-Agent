(() => {
  'use strict';
  const find = (node, name) => node.querySelector(`[data-pencil-name="${name}"]`);
  const clamp = (n, a = 0, b = 1) => Math.max(a, Math.min(b, n));
  const mix = (a, b, t) => a + (b - a) * t;
  const smooth = (a, b, n) => { const t = clamp((n - a) / (b - a)); return t * t * (3 - 2 * t); };
  const frames = ['X6TEl','FOaUd','rtoIL','U1jyYe','YCCml'].map(id => document.querySelector(`[data-pencil-id="${id}"]`));
  const [root, questionFrame, answerFrame, readyFrame, home] = frames;
  const oldWrapper = document.body.firstElementChild;
  const shell = document.createElement('div'); shell.id = 'shell';
  const hostLabel = document.createElement('p'); hostLabel.className = 'host-label'; hostLabel.textContent = 'MoMoAgent · 未来体验设计预览';
  const phone = document.createElement('main'); phone.id = 'phone'; phone.setAttribute('aria-label','MoMoAgent Personal Agent 首次体验');
  root.id = 'landing'; phone.append(root);
  const controls = document.createElement('nav'); controls.className = 'host-controls'; controls.setAttribute('aria-label','设计预览控制');
  controls.innerHTML = '<button id="host-replay">重播体验</button><button id="host-back">返回体验</button><button id="host-theme">深色</button>';
  shell.append(hostLabel,phone,controls); document.body.append(shell);

  const move = (node, id) => { node.id = id; root.append(node); return node; };
  const nativeButton = (node, id, label) => {
    const button = document.createElement('button'); button.id = id; button.style.cssText = node.style.cssText;
    button.dataset.pencilName = node.dataset.pencilName; button.append(...node.childNodes); button.setAttribute('aria-label',label); node.replaceWith(button); return button;
  };
  const avatar = find(root,'同一个 Avatar · Personal Agent'); avatar.id = 'avatar'; avatar.replaceChildren();
  const avatarController = MoMoAvatar.create(avatar,{size:280}); const actorBody = avatar.querySelector('.life-avatar');
  const brand = find(root,'原始品牌资产 · 不改色'); brand.id = 'shared-brand';
  const voices = ['生活原话一','生活原话二'].map((name,i) => {const n = find(root,name); n.id = 'voice-'+i; return n;});
  const introTitle = find(root,'唯一主张'); introTitle.id = 'intro-title';
  const readyTitle = move(find(readyFrame,'唯一主张'),'ready-title');
  const user = move(find(questionFrame,'用户说 · 气泡'),'user-message');
  const typing = move(find(questionFrame,'Agent 正在回应'),'typing');
  const answer = move(find(answerFrame,'Agent 回答'),'agent-message');
  const ticket = move(find(answerFrame,'旅程上下文 · 待确认'),'trip-context');
  const source = nativeButton(move(find(answerFrame,'查看生活依据'),'source-link'),'source-link','查看这次旅程的生活原话');
  const primary = nativeButton(move(find(readyFrame,'开始使用 · 进入聊天首页'),'primary'),'primary','开始使用 MoMoAgent');
  const replay = nativeButton(move(find(readyFrame,'继续体验 · 可返回'),'replay'),'replay','重新观看首次体验');
  const dots = [...root.children].filter(n=>n.dataset.pencilName?.startsWith('体验进度'));
  const sourcePanel = document.createElement('section'); sourcePanel.id='source-panel'; sourcePanel.hidden=true;
  sourcePanel.setAttribute('aria-label','示例生活原话'); sourcePanel.innerHTML='<button id="close-source" aria-label="收起生活原话">收起</button><p>“11 月 20 号，去大理吧。”</p><p>“从上海走，晚点出发。”</p>'; root.append(sourcePanel);
  find(root,'系统动态岛代理').classList.add('native-island');

  find(home,'Avatar 归位 · 同一角色').remove(); find(home,'顶部品牌图标 · 原始资产').remove();
  home.id='home-design'; const entry=document.createElement('section'); entry.id='entry'; entry.setAttribute('aria-label','聊天首页设计预览'); entry.inert=true; entry.append(home); root.append(entry);
  const homeIndicator=[...home.children].find(n=>n.dataset.pencilName==='rectangle'&&parseFloat(n.style.top)>800);
  [...home.children].find(n=>n.dataset.pencilName==='rectangle'&&parseFloat(n.style.top)<40)?.classList.add('native-island');
  const homeGreeting=find(home,'你想做点什么？'); const homeComposer=find(home,'说说你想做的事…'); homeComposer.textContent='';
  const homeInput=document.createElement('input'); homeInput.id='home-input'; homeInput.placeholder='说说你想做的事…'; homeInput.setAttribute('aria-label','给你的 Personal Agent 发消息，设计预览'); homeComposer.append(homeInput);
  const feedback=document.createElement('p'); feedback.id='home-feedback'; feedback.setAttribute('role','status'); home.append(feedback);
  const ground=document.createElement('div'); ground.id='avatar-ground'; ground.setAttribute('aria-hidden','true'); root.append(ground);
  oldWrapper.remove();
  const colors={'#FAFAFA':'var(--bg)','#fafafa':'var(--bg)','#F1F1F1':'var(--surface)','#f1f1f1':'var(--surface)','#FFFFFF':'var(--paper)','#ffffff':'var(--paper)','#252525':'var(--ink)','#707070':'var(--muted)'};
  [root,...root.querySelectorAll('*')].forEach(n=>{
    if(n.hasAttribute('style'))n.setAttribute('style',n.getAttribute('style').replace(/#[0-9a-fA-F]{6}\b/g,c=>colors[c]||c));
    for(const a of ['fill','stroke'])if(colors[n.getAttribute(a)])n.setAttribute(a,colors[n.getAttribute(a)]);
  });

  const scenarios = [
    {moments:['11 月 20 号，去大理吧。','从上海走，晚点出发。'],source:'生活里的聊天',title:'旅行，接着安排。',request:'把行程安排一下。',reply:'你们的大理之行，\n我接着安排。',task:'旅行安排',result:'上海 → 大理',detail:'11 月 20 日 · 晚间出发',context:'已带上出发偏好',origin:'来自你们的聊天'},
    {moments:['周五给林总发新版方案。','预算那页，按邮件里的改。'],source:'刚才的会议',title:'说过的事，接着做。',request:'把刚才答应的跟进一下。',reply:'林总那份方案，\n我接着改。',task:'工作跟进',result:'林总 · 新版方案',detail:'周五前 · 更新预算页',context:'会议 × 邮件 × 项目资料',origin:'来自会议和邮件'},
    {moments:['下周六是妈妈生日。','她喜欢清淡的，最近走路不方便。'],source:'家人间的聊天',title:'在意的人，也记着。',request:'她生日那天安排一下。',reply:'妈妈的生日，\n找家清淡、少走路的。',task:'家人安排',result:'妈妈的生日晚餐',detail:'下周六 · 清淡 · 方便到达',context:'关系 × 长期偏好',origin:'来自家人间的聊天'}
  ];
  let scenarioIndex=0, recycling=false;const episodesSeen=new Set();
  function updateScenario(){const s=scenarios[scenarioIndex];voices.forEach((n,i)=>find(n,'生活原话').textContent=s.moments[i]);find(voices[0],'原话来源').textContent=s.source;introTitle.textContent=s.title;find(user,'用户原话').textContent=s.request;find(answer,'回答正文').textContent=s.reply;for(const [name,value] of [['任务状态',s.task],['行程目的地',s.result],['已知出发要求',s.detail],['行动边界',s.context]])find(ticket,name).textContent=value;source.textContent=s.origin;source.setAttribute('aria-label','查看这次请求的上下文');sourcePanel.querySelectorAll('p').forEach((n,i)=>n.textContent='“'+s.moments[i]+'”');}
  const reduced=matchMedia('(prefers-reduced-motion: reduce)');
  const actorPoints=[[56.5,226,280],[18,334,72],[18,334,72],[96.5,225,200]];
  const holdTimes=[2900,650,2300,Infinity];
  let p=0,velocity=0,goal=0,intro=reduced.matches?1:0,introVelocity=0,phaseTime=0,settled=true,completed=false,visited=[true,false,false,false];
  let raf=0,last=0,background=false,inspecting=false,scale=1,virtualHeight=852,avatarActive=false,gestureAnimation=null,ticking=false;
  let homeProgress=0,homeVelocity=0,homeTarget=0,entered=false,homeFrom=actorPoints[3].slice(),homeResolve=null;
  let transitionResolve=null; const samples=[]; let trace=false;
  const fontNodes=[...root.querySelectorAll('[data-pencil-name]')].filter(n=>parseFloat(n.style.fontSize)>0).map(node=>({node,size:parseFloat(node.style.fontSize),line:parseFloat(node.style.lineHeight)}));
  const landingNodes=[...root.children].filter(n=>![avatar,brand,entry,ground].includes(n)&&!n.dataset.pencilName?.startsWith('系统'));
  const actorAt = value => {const n=clamp(value,0,3),i=Math.min(2,Math.floor(n));return actorPoints[i].map((v,j)=>mix(v,actorPoints[i+1][j],n-i));};
  const visible = (n,amount,dy=0) => {n.style.opacity=String(amount);n.style.visibility=amount<.001?'hidden':'visible';n.style.transform=`translate3d(0,${dy}px,0)`;n.inert=amount<.95;n.setAttribute('aria-hidden',String(amount<.95));};
  function setAvatarActive(value){if(avatarActive!==value){avatarActive=value;avatarController.setActive(value);}}
  function stopGreeting(){gestureAnimation?.cancel();gestureAnimation=null;actorBody.style.transform='';}
  function smallReaction(){if(reduced.matches||homeProgress>0&&homeProgress<1)return;stopGreeting();gestureAnimation=actorBody.animate([{transform:'translateY(0) scale(1,1)'},{transform:'translateY(3px) scale(1.05,.94)',offset:.2},{transform:'translateY(-22px) rotate(-5deg)',offset:.52},{transform:'translateY(1px) scale(1.03,.96)',offset:.8},{transform:'translateY(0) scale(1,1)'}],{duration:500,easing:'cubic-bezier(.25,.1,.25,1)'});}
  function paint(){
    const a=actorAt(p);const attention=goal===0&&!reduced.matches?Math.sin(clamp(phaseTime/3000)*Math.PI*2)*2.5:0;
    const returnHop=reduced.matches?0:36*Math.sin(Math.PI*clamp(p-2));
    avatar.style.transform=`translate3d(${a[0]}px,${a[1]+(1-intro)*22-returnHop}px,0) scale(${a[2]/280})`;
    avatar.style.opacity=String(smooth(0,.55,intro));avatar.style.filter=reduced.matches?'none':`blur(${(1-intro)*3}px)`;
    const catchPulse=Math.sin(Math.PI*clamp(p));if(!gestureAnimation)actorBody.style.transform=reduced.matches?'none':`rotate(${attention-4*catchPulse}deg) scale(${1+catchPulse*.04},${1-catchPulse*.03})`;
    const capture=smooth(.02,.82,p),focus=1-smooth(.08,.65,p);
    voices.forEach((n,i)=>{const age=phaseTime-(i?1250:250),arrival=goal===0&&!recycling?smooth(0,350,age):recycling?0:1;const start=i?[140,441]:[24,173],width=i?229:278,height=i?64:76;const x=mix(start[0],a[0]+a[2]*.5-width*.04,capture),y=mix(start[1],a[1]+a[2]*.32-height*.04,capture)-(i?-1:1)*Math.sin(capture*Math.PI)*30;
      n.style.transform=`translate3d(${x}px,${y+(1-arrival)*12}px,0) scale(${1-capture*.92}) rotate(${capture*(i?8:-8)}deg)`;n.style.opacity=String(arrival*focus);n.style.visibility=arrival*focus<.002?'hidden':'visible';n.inert=arrival*focus<.95;
    });
    visible(introTitle,(recycling?0:1)*(1-smooth(.05,.62,p))*smooth(.2,.9,intro),(1-intro)*8); introTitle.style.top=(virtualHeight-294)+'px';
    const conversation=(recycling?0:1)*smooth(.18,.94,p)*(1-smooth(2.12,2.82,p));
    visible(user,conversation,12*(1-conversation));
    const listening=smooth(.75,1,p)*(1-smooth(1.08,1.65,p));visible(typing,listening);
    [...typing.children].forEach((n,i)=>n.style.transform=reduced.matches?'none':`translateY(${-Math.max(0,Math.sin(phaseTime/125+i*.8))*3}px)`);
    const response=(recycling?0:1)*smooth(1.25,1.94,p)*(1-smooth(2.06,2.76,p));
    visible(answer,response,(1-response)*6);visible(ticket,(recycling?0:1)*smooth(1.5,2,p)*(1-smooth(2.08,2.8,p)),(1-response)*14);visible(source,response);
    visible(sourcePanel,inspecting&&goal===2?1:0);
    const ready=smooth(2.25,2.98,p);visible(readyTitle,ready,(1-ready)*10);readyTitle.style.top=(virtualHeight-321)+'px';
    const unlocked=completed&&goal===3&&settled&&homeProgress===0&&!entered;
    primary.disabled=!unlocked;primary.hidden=!unlocked;replay.hidden=!unlocked;
    primary.style.top=(virtualHeight-134)+'px';replay.style.top=(virtualHeight-74)+'px';
    primary.style.height=Math.max(52,44.2/scale)+'px';replay.style.height=Math.max(44,44.2/scale)+'px';
    dots.forEach((n,i)=>{n.style.top=(virtualHeight-62)+'px';n.style.opacity=goal===3?'0':i===scenarioIndex?'1':'.22';});
    find(root,'系统 Home Indicator 代理').style.top=(virtualHeight-19)+'px';
    avatar.style.pointerEvents='auto';avatar.setAttribute('role','button');avatar.tabIndex=0;avatar.setAttribute('aria-label',entered?'你的 Personal Agent，点击打个招呼':'和你的 Personal Agent 打个招呼');
    root.dataset.scenario=String(scenarioIndex);root.dataset.stage=String(goal);root.dataset.complete=String(completed);root.dataset.entered=String(entered);root.dataset.background=String(background);
    setAvatarActive(!background&&!reduced.matches&&!entered&&!inspecting&&goal<3);
    if(homeProgress>0||entered)paintHome();else brand.style.transform='translate3d(28px,84px,0)';
  }
  function arrive(){if(recycling&&goal===0){recycling=false;updateScenario();}settled=true;p=goal;velocity=0;visited[goal]=true;if(goal===3&&visited.every(Boolean)&&episodesSeen.size===scenarios.length)completed=true;phaseTime=0;const done=transitionResolve;transitionResolve=null;if(done)done(true);}
  function go(index){if(homeProgress>0||entered)return leave().then(ok=>ok?go(index):false);if(transitionResolve)transitionResolve(false);goal=clamp(Math.round(index),0,3);settled=false;inspecting=false;sourcePanel.hidden=true;stopGreeting();
    const promise=new Promise(resolve=>transitionResolve=resolve);if(reduced.matches){p=goal;intro=1;arrive();paint();}start();return promise;}
  function replayStory(){if(homeProgress>0||entered)return leave().then(ok=>ok?replayStory():false);if(transitionResolve){transitionResolve(false);transitionResolve=null;}scenarioIndex=0;recycling=false;episodesSeen.clear();updateScenario();p=0;velocity=0;goal=0;phaseTime=0;visited=[true,false,false,false];completed=false;settled=true;inspecting=false;sourcePanel.hidden=true;intro=reduced.matches?1:0;introVelocity=0;stopGreeting();paint();start();}
  function paintHome(){
    const h=homeProgress,flight=smooth(.14,.72,h),land=smooth(.72,1,h),offset=(virtualHeight-852)/2;
    const anticipation=Math.sin(Math.PI*smooth(0,.14,h))*(1-smooth(.13,.15,h));const rebound=Math.sin(land*Math.PI*2)*Math.pow(1-land,1.5);
    const size=mix(homeFrom[2],120,flight),x=mix(homeFrom[0],136.5,flight),y=mix(homeFrom[1],251+offset,flight)-100*Math.sin(Math.PI*flight);
    avatar.style.transform=`translate3d(${x}px,${y}px,0) scale(${size/280})`;avatar.style.opacity='1';avatar.style.filter='none';actorBody.style.transform=`rotate(${-10*Math.sin(Math.PI*flight)-2.5*rebound}deg) scale(${1+anticipation*.1+rebound*.08},${1-anticipation*.12-rebound*.1})`;
    const icon=smooth(.02,.55,h);brand.style.transform=`translate3d(${mix(28,122,icon)}px,${mix(84,58,icon)}px,0) scale(${mix(1,24/28,icon)})`;
    entry.style.display=h>.02||entered?'block':'none';entry.style.opacity=String(smooth(.05,.26,h));entry.inert=homeTarget===0||h<.12;
    landingNodes.forEach(n=>{n.style.visibility=h>.18?'hidden':'';n.style.opacity=String(1-smooth(0,.16,h));n.inert=true;});
    ground.style.opacity=String(.06*smooth(.55,.82,h));ground.style.transform=`translate3d(174.5px,${343+offset}px,0)`;
    root.dataset.sharedActive=String(h>0||entered);root.dataset.entered=String(entered);avatar.style.pointerEvents=h===1?'auto':'none';
    home.style.height=virtualHeight+'px';if(homeIndicator)homeIndicator.style.top=(virtualHeight-19)+'px';homeGreeting.style.top=(372+offset)+'px';homeComposer.parentElement.style.top=(435+offset)+'px';feedback.style.top=(510+offset)+'px';
    primary.disabled=true;primary.hidden=true;replay.hidden=true;setAvatarActive(false);
  }
  function completeHome(value){homeProgress=value;homeVelocity=0;entered=value===1;stopGreeting();
    if(value===0){entry.style.display='none';entry.inert=true;root.dataset.sharedActive='false';ground.style.opacity='0';landingNodes.forEach(n=>{n.style.visibility='';n.style.opacity='';n.inert=false;});paint();}
    else{paintHome();if(document.activeElement===primary)homeInput.focus({preventScroll:true});}
    const done=homeResolve;homeResolve=null;if(done)done(true);
  }
  function driveHome(value){if(homeResolve)homeResolve(false);homeTarget=value;const promise=new Promise(resolve=>homeResolve=resolve);if(reduced.matches)completeHome(value);else start();return promise;}
  function enter(){if(!completed||goal!==3||!settled)return Promise.resolve(false);if(homeProgress===0){const m=new DOMMatrixReadOnly(getComputedStyle(avatar).transform);homeFrom=[m.m41,m.m42,Math.hypot(m.a,m.b)*280];}stopGreeting();entered=true;return driveHome(1);}
  function leave(){stopGreeting();entered=false;if(homeProgress===0){homeTarget=0;completeHome(0);return Promise.resolve(true);}return driveHome(0);}
  function frame(now){raf=0;ticking=true;if(background){ticking=false;return;}const dt=last?Math.min(.032,(now-last)/1000):1/60;last=now;
    if(homeProgress>0&&homeProgress<1||homeTarget===1&&homeProgress===0||homeTarget===0&&homeProgress===1&&homeResolve){
      homeVelocity+=((homeTarget===1?1.42:-1.8)-homeVelocity)*(1-Math.exp(-dt*18));homeProgress=clamp(homeProgress+homeVelocity*dt);paintHome();
      if(homeTarget===1&&homeProgress===1||homeTarget===0&&homeProgress===0)completeHome(homeTarget);
    }else if(!entered){
      for(let i=0;i<2;i++){const step=dt/2;velocity+=(-280*(p-goal)-29*velocity)*step;p+=velocity*step;introVelocity+=(-260*(intro-1)-29*introVelocity)*step;intro+=introVelocity*step;}
      intro=clamp(intro);if(Math.abs(1-intro)<.0003&&Math.abs(introVelocity)<.004){intro=1;introVelocity=0;}
      if(!settled&&Math.abs(p-goal)<.0003&&Math.abs(velocity)<.004)arrive();
      if(settled&&!inspecting)phaseTime+=dt*1000;paint();
      if(settled&&intro===1&&goal<3&&phaseTime>=holdTimes[goal]){if(goal===2){episodesSeen.add(scenarioIndex);if(scenarioIndex+1<scenarios.length){scenarioIndex++;recycling=true;go(0);}else go(3);}else go(goal+1);}
    }
    if(trace)samples.push({t:now,p,goal,home:homeProgress,homeVelocity,complete:completed,primaryVisible:!primary.hidden});
    ticking=false;if(!background&&(!entered&&(goal<3&&!inspecting||!settled||intro!==1)||homeResolve))raf=requestAnimationFrame(frame);else last=0;
  }
  function start(){if(!raf&&!background&&!ticking){last=0;raf=requestAnimationFrame(frame);}}
  primary.onclick=()=>enter();replay.onclick=replayStory;document.getElementById('host-replay').onclick=replayStory;document.getElementById('host-back').onclick=()=>leave();
  avatar.onclick=smallReaction;avatar.onkeydown=e=>{if(e.key==='Enter'||e.key===' '){e.preventDefault();smallReaction();}};
  source.onclick=()=>{inspecting=true;sourcePanel.hidden=false;source.setAttribute('aria-expanded','true');paint();};
  document.getElementById('close-source').onclick=()=>{inspecting=false;sourcePanel.hidden=true;source.setAttribute('aria-expanded','false');paint();start();};
  homeInput.onkeydown=e=>{if(e.key==='Enter'){e.preventDefault();feedback.textContent='设计预览 · 连接 AI 服务后即可对话';}};
  function theme(value){document.documentElement.dataset.theme=value;document.getElementById('host-theme').textContent=value==='dark'?'浅色':'深色';}
  document.getElementById('host-theme').onclick=()=>theme(document.documentElement.dataset.theme==='dark'?'light':'dark');
  function fit(){const width=document.documentElement.clientWidth||innerWidth,height=document.documentElement.clientHeight||innerHeight,mobile=width<=460;scale=mobile?width/393:Math.min(1,(width-48)/393,(height-135)/852);virtualHeight=mobile?Math.max(852,height/scale):852;
    phone.style.width=393*scale+'px';phone.style.height=virtualHeight*scale+'px';root.style.height=virtualHeight+'px';root.style.transform=`scale(${scale})`;
    fontNodes.forEach(({node,size,line})=>{const min=size<=13?12:14,next=mobile?Math.max(size,min/scale):size;node.style.fontSize=next+'px';if(line)node.style.lineHeight=line*next/size+'px';});
    find(root,'产品类别').style.top=(mobile&&scale<.9?112:105)+'px';sourcePanel.style.fontSize=Math.max(14,14/scale)+'px';document.getElementById('close-source').style.minHeight=Math.max(44,44.2/scale)+'px';paint();
  }
  addEventListener('resize',fit);
  document.addEventListener('visibilitychange',()=>{background=document.hidden;last=0;if(background){cancelAnimationFrame(raf);raf=0;setAvatarActive(false);stopGreeting();}else start();});
  reduced.addEventListener('change',()=>{setAvatarActive(false);stopGreeting();intro=1;introVelocity=0;if(!settled){p=goal;arrive();}if(homeResolve)completeHome(homeTarget);paint();start();});
  updateScenario();theme(matchMedia('(prefers-color-scheme: dark)').matches?'dark':'light');fit();paint();start();
  window.preview={go,enter,leave,replay:replayStory,theme,state:()=>({scenario:scenarioIndex,episodesSeen:[...episodesSeen],progress:p,target:goal,settled,completed,visited:[...visited],phaseTime,entered,homeProgress,homeVelocity,homeAnimating:!!homeResolve,reduced:reduced.matches,avatarCount:document.querySelectorAll('.life-avatar').length,avatarActive,primaryVisible:!primary.hidden,primaryDisabled:primary.disabled,sourceOpen:inspecting,width:document.documentElement.clientWidth}),trace(value=true){trace=value;if(value)samples.length=0;return samples;},samples:()=>samples};
})();
