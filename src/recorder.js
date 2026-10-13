(() => {
  if (globalThis.__startRec) return 'already';
  const cp = require('child_process');
  globalThis.__recorders = globalThis.__recorders || {};

  globalThis.__startRec = (winid, outpath, fps, crf) => {
    const win = electron.BrowserWindow.fromId(winid);
    const wc = win.webContents;
    return new Promise((resolve, reject) => {
      let started = false, lastBuf = null, ff = null, timer = null;
      const onFrame = (image) => {
        lastBuf = image.toBitmap();
        if (started) return;
        started = true;
        const sz = image.getSize();
        const args = [
          '-y', '-f', 'rawvideo', '-pix_fmt', 'bgra',
          '-s', sz.width + 'x' + sz.height, '-r', String(fps),
          '-i', '-',
          '-vf', 'crop=trunc(iw/2)*2:trunc(ih/2)*2,format=yuv420p',
          '-c:v', 'libx264', '-preset', 'fast', '-crf', String(crf),
          '-movflags', '+faststart', outpath
        ];
        ff = cp.spawn('ffmpeg', args, {stdio: ['pipe', 'ignore', 'pipe']});
        let errbuf = '';
        ff.stderr.on('data', d => { errbuf += d; if (errbuf.length > 4000) errbuf = errbuf.slice(-4000); });
        ff.on('error', e => {});
        const rec = globalThis.__recorders[winid];
        if (rec) { rec.ff = ff; rec.getTimer = () => timer; rec.errbuf = () => errbuf; }
        // Constant-fps pump: re-emit the latest frame every 1000/fps ms so the
        // output has a steady frame rate even while the page is idle. While
        // PAUSED we simply stop writing — ffmpeg gets no frames for that span,
        // so it is EXCISED from the output (the video jumps straight from the
        // last pre-pause frame to the first post-resume one). lastBuf keeps
        // updating from the live subscription, so resume picks up the current
        // frame with no stale flash.
        timer = setInterval(() => {
          const r = globalThis.__recorders[winid];
          if (r && !r.paused && lastBuf && ff && ff.stdin.writable) {
            try { ff.stdin.write(lastBuf); } catch (e) {}
          }
        }, Math.round(1000 / fps));
        resolve({width: sz.width, height: sz.height});
      };
      globalThis.__recorders[winid] = {wc, onFrame, ff: null, paused: false, getTimer: () => timer, getFf: () => ff};
      wc.beginFrameSubscription(false, onFrame);
      wc.invalidate();
      setTimeout(() => { if (!started) reject('no frame within 5s'); }, 5000);
    });
  };

  globalThis.__stopRec = (winid) => {
    const rec = globalThis.__recorders[winid];
    if (!rec) return Promise.resolve('no recorder');
    const ff = rec.getFf ? rec.getFf() : rec.ff;
    const timer = rec.getTimer ? rec.getTimer() : null;
    return new Promise((resolve) => {
      try { rec.wc.endFrameSubscription(); } catch (e) {}
      if (timer) clearInterval(timer);
      if (ff && ff.stdin.writable) {
        ff.on('close', (code) => { delete globalThis.__recorders[winid]; resolve('done code=' + code); });
        try { ff.stdin.end(); } catch (e) { resolve('stdin-end-error'); }
      } else {
        delete globalThis.__recorders[winid];
        resolve('no ffmpeg');
      }
    });
  };

  // Pause/resume the constant-fps pump. Paused frames are never written, so the
  // paused span is cut out of the output entirely (not frozen). No-op if the
  // window isn't recording.
  globalThis.__pauseRec = (winid) => {
    const rec = globalThis.__recorders[winid];
    if (rec) rec.paused = true;
    return rec ? 'paused' : 'no recorder';
  };
  globalThis.__resumeRec = (winid) => {
    const rec = globalThis.__recorders[winid];
    if (rec) rec.paused = false;
    return rec ? 'resumed' : 'no recorder';
  };
  return 'defined';
})()
