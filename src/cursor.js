(() => {
  if (window.__fc) return 'already';
  const NS = 'http://www.w3.org/2000/svg';
  const wrap = document.createElement('div');
  wrap.id = '__fake_cursor';
  wrap.style.cssText = 'position:fixed;left:0;top:0;width:28px;height:28px;z-index:2147483647;'
    + 'pointer-events:none;transform:translate(-3px,-2px);will-change:left,top,transform;'
    + 'filter:drop-shadow(1px 2px 2px rgba(0,0,0,0.45));transition:transform 0.08s ease;';
  wrap.innerHTML = '<svg width="28" height="28" viewBox="0 0 24 24" xmlns="' + NS + '">'
    + '<path d="M4 1.5 L4 19.5 L9.1 14.7 L12.6 22 L15.3 20.8 L11.8 13.7 L18.5 13.7 Z" '
    + 'fill="#ffffff" stroke="#1a1a1a" stroke-width="1.3" stroke-linejoin="round"/></svg>';
  document.body.appendChild(wrap);

  const ripple = document.createElement('div');
  ripple.style.cssText = 'position:fixed;left:0;top:0;width:0;height:0;border-radius:50%;'
    + 'z-index:2147483646;pointer-events:none;border:2px solid rgba(80,160,255,0.9);'
    + 'opacity:0;transform:translate(-50%,-50%);';
  document.body.appendChild(ripple);

  const fc = window.__fc = {x: window.innerWidth/2, y: window.innerHeight/2, down: false, button: 0};
  const place = () => { wrap.style.left = fc.x + 'px'; wrap.style.top = fc.y + 'px'; };
  place();

  function dispatchAt(type, x, y, extra) {
    const el = document.elementFromPoint(x, y) || document.body;
    const opts = Object.assign({clientX: x, clientY: y, bubbles: true, cancelable: true,
      view: window, composed: true}, extra || {});
    if (type.startsWith('pointer')) el.dispatchEvent(new PointerEvent(type, Object.assign({pointerId:1, pointerType:'mouse', isPrimary:true}, opts)));
    else el.dispatchEvent(new MouseEvent(type, opts));
    return el;
  }

  // saccadic-ish easing: quick start, gentle settle
  const ease = (t) => t<0.5 ? 4*t*t*t : 1-Math.pow(-2*t+2,3)/2;

  fc.moveTo = (tx, ty, dur) => new Promise((resolve) => {
    const sx = fc.x, sy = fc.y;
    if (dur <= 0) { fc.x=tx; fc.y=ty; place(); dispatchAt(fc.down?'pointermove':'mousemove', tx, ty, fc.down?{buttons:1}:{}); return resolve(); }
    const t0 = performance.now();
    const step = (now) => {
      let p = Math.min(1, (now - t0) / (dur*1000));
      const e = ease(p);
      fc.x = sx + (tx-sx)*e; fc.y = sy + (ty-sy)*e;
      place();
      if (fc.down) { dispatchAt('pointermove', fc.x, fc.y, {buttons:1}); dispatchAt('mousemove', fc.x, fc.y, {buttons:1}); }
      else dispatchAt('mousemove', fc.x, fc.y);
      if (p < 1) requestAnimationFrame(step); else resolve();
    };
    requestAnimationFrame(step);
  });

  fc.press = (button) => {
    fc.down = true; fc.button = button||0;
    wrap.style.transform = 'translate(-3px,-2px) scale(0.82)';
    const b = fc.button;
    dispatchAt('pointerdown', fc.x, fc.y, {button:b, buttons: b===0?1:b===2?2:4});
    dispatchAt('mousedown', fc.x, fc.y, {button:b, buttons: b===0?1:b===2?2:4});
    ripple.style.borderColor = 'rgba(80,160,255,0.9)';
    ripple.style.left = fc.x+'px'; ripple.style.top = fc.y+'px';
    ripple.style.transition='none'; ripple.style.width='6px'; ripple.style.height='6px'; ripple.style.opacity='0.9';
    requestAnimationFrame(()=>{ ripple.style.transition='all 0.4s ease-out'; ripple.style.width='34px'; ripple.style.height='34px'; ripple.style.opacity='0'; });
    return Promise.resolve();
  };
  fc.release = (doClick) => {
    const b = fc.button;
    wrap.style.transform = 'translate(-3px,-2px) scale(1)';
    dispatchAt('pointerup', fc.x, fc.y, {button:b, buttons:0});
    dispatchAt('mouseup', fc.x, fc.y, {button:b, buttons:0});
    if (doClick) dispatchAt('click', fc.x, fc.y, {button:b});
    fc.down = false;
    return Promise.resolve();
  };
  fc.setPos = (x,y) => { fc.x=x; fc.y=y; place(); };

  return 'installed';
})()
