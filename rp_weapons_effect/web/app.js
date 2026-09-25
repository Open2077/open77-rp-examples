(() => {
  'use strict';
  const $ = id => document.getElementById(id);
  let config, selected, tuning = {}, profileRevision=-1;
  let lastBlasts=0, lastImpulses=0, lastForeign=0;
  const fields = [
    ['reloadSpeed','Reload speed','handling',0.25,'×'],
    ['fireRate','Fire rate','handling',0.25,'×'],
    ['recoil','Recoil','handling',0.1,'×'],
    ['spread','Spread','handling',0.1,'×'],
    ['blastRadius','Radius','blast',1,' m'], ['blastPush','Outward push','blast',1,''],
    ['blastLift','Upward lift','blast',1,''], ['blastFalloff','Distance falloff','blast',0.25,''],
    ['blastCooldown','Minimum interval','blast',0.05,' s'],
    ...window.WeaponWorkshopExtras.fields
  ];
  const send = (action, extra={}) => Open77.emit('weapons:action', {action,...extra});
  function update() {
    for (const [key,,,,unit] of fields) {
      $(key).value = tuning[key]; $(key+'-value').textContent = Number(tuning[key]).toFixed(2).replace(/\.00$/,'')+unit;
    }
  }
  function choose(weapon) {
    selected = weapon.record; $('weapon-name').textContent = weapon.label;
    for (const button of $('weapons').children) button.classList.toggle('selected',button.dataset.record===selected);
  }
  function initialize(value) {
    if (config) return;
    config = value; tuning = {...config.defaults};
    for (const [key,label,group,step,unit] of fields) {
      const row=document.createElement('div'); row.className='field';
      const caption=document.createElement('label'); caption.htmlFor=key; caption.textContent=label;
      const output=document.createElement('output'); output.id=key+'-value'; output.htmlFor=key; caption.append(output);
      const input=document.createElement('input'); input.type='range'; input.id=key;
      [input.min,input.max]=config.ranges[key]; input.step=step;
      input.oninput=()=>{tuning[key]=Number(input.value); update();};
      row.append(caption,input); $(group).append(row);
    }
    for (const preset of config.presets) {
      const button=document.createElement('button'); button.textContent=preset.label;
      button.onclick=()=>{tuning={...config.defaults,...preset.values};update();$('result').textContent='Preset ready. Apply it to test.';}; $('presets').append(button);
    }
    update();
  }
  function rows(id, values) {
    $(id).replaceChildren();
    for (const [label,value] of values) {
      const term=document.createElement('dt'), detail=document.createElement('dd');
      term.textContent=label; detail.textContent=value; $(id).append(term,detail);
    }
  }
  Open77.on('weapons:catalog',page=>{
    if (page.offset===1) $('weapons').replaceChildren();
    for (const weapon of (Array.isArray(page.items)?page.items:[])) {
      const button = document.createElement('button'); button.dataset.record=weapon.record;
      const title=document.createElement('strong'); title.textContent=weapon.label;
      const caption=document.createElement('small'); caption.textContent=weapon.category;
      button.append(title,caption); button.onclick=()=>choose(weapon); $('weapons').append(button);
      if (!selected || selected===weapon.record) choose(weapon);
    }
  });
  Open77.on('weapons:config',initialize);
  Open77.on('weapons:open',()=>{$('workshop').hidden=false;$('close').focus();});
  Open77.on('weapons:closed',()=>{$('workshop').hidden=true;});
  Open77.on('weapons:state',value=>{
    if (config && value.profileRevision !== profileRevision) {
      profileRevision=value.profileRevision;
      if (value.profile) {
        tuning={...config.defaults,...value.profile.tuning};
        const button=[...$('weapons').children].find(b=>b.dataset.record===value.profile.record);
        if (button) choose({record:value.profile.record,label:button.querySelector('strong').textContent});
        update();
      } else {
        tuning={...config.defaults}; update();
      }
    }
    $('active').textContent=value.active?'ACTIVE':'WAITING'; $('active').classList.toggle('active',!!value.active);
    $('status').textContent=({unsupported_client:'This client needs native weapon tuning support. Please update it.',idle:'No active settings.',active:'Settings active on your held weapon.',waiting_for_weapon:'Draw the configured weapon to activate its settings.',restoring:'Draw the previously tuned weapon to finish restoring its stats.',waiting_for_restore:'Restoring the previous settings before applying the new profile.'})[value.status] || 'Settings not applied: '+value.status;
    const stats=value.stats||{};
    rows('stats',[['Reload',stats.reloadTime],['Empty reload',stats.emptyReloadTime],['Shot cycle',stats.cycleTime],['Maximum recoil',stats.recoilKickMax],['Spread X',stats.spreadMaxX]].map(([k,v])=>[k,Number.isFinite(v)?v.toFixed(3):'—']));
    rows('extra-stats',window.WeaponWorkshopExtras.statRows(stats));
    rows('counters',[['Blasts',value.blasts||0],['Projectile contacts',value.projectileContacts||0],['Queued car impulses',value.impulsesQueued||0],['Other car owner',value.foreignSkipped||0],['Failures',value.failures||0]]);
    if (Number.isFinite(value.blasts) && value.blasts > lastBlasts) {
      const applied=(value.impulsesQueued||0)-lastImpulses;
      const skipped=(value.foreignSkipped||0)-lastForeign;
      $('blast-feedback').textContent=applied>0
        ? 'Last blast: sent to '+applied+' car(s) simulated by your client.'
        : skipped>0 ? 'Car impulses blocked: nearby cars are not simulated by your client. Use a passenger fleet with host physics.'
        : 'Last blast: no eligible cars in range. The cars may be frozen or outside the radius.';
      $('blast-feedback').classList.toggle('error',applied===0);
    }
    if (Number.isFinite(value.blasts)) {
      lastBlasts=value.blasts; lastImpulses=value.impulsesQueued||0; lastForeign=value.foreignSkipped||0;
    }
  });
  Open77.on('weapons:result',value=>{$('result').textContent=value.message;$('result').classList.toggle('error',!value.ok);});
  Open77.on('weapons:characters',value=>{
    const nearest=Array.isArray(value.closest)&&value.closest[0];
    $('result').textContent='Characters: '+value.accepted+' launch request(s) authorized, '+value.rejected+' refused.'
      +(nearest?' Nearest #'+nearest.player+': '+nearest.reason+'; life '+nearest.life+', previous motion '+nearest.previous+'.':'')
      +' Verify their movement in game.';
    $('result').classList.remove('error');
  });
  $('search').oninput=()=>{const q=$('search').value.toLocaleLowerCase();for(const b of $('weapons').children)b.hidden=!b.textContent.toLocaleLowerCase().includes(q);};
  $('apply').onclick=()=>send('apply',{record:selected,tuning});
  $('equip').onclick=()=>send('equip',{record:selected});
  $('ammo').onclick=()=>send('ammo'); $('grenades').onclick=()=>send('grenades');
  $('holster').onclick=()=>send('holster');
  $('reset').onclick=()=>{tuning={...config.defaults};update();send('reset');};
  const close=()=>Open77.emit('weapons:close',{}); $('close').onclick=close;
  document.addEventListener('keydown',e=>{if(e.key==='Escape')close();});
  Open77.ready(); Open77.emit('weapons:ready',{});
})();
