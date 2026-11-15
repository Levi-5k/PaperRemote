// Opening waterfall. Characters pour out of the word, bump each other, and pile
// on the bottom edge. Tilt steers gravity. About two seconds.
(function (root) {
  const REST_DROP = 0.42;
  const REST_FLOOR = 0.16;
  const FLOOR_GRIP = 0.84;

  function stepParticles(particles, width, height, gravity, dt) {
    let remaining = Math.min(Math.max(dt, 0), 0.033);
    const floor = height;
    for (let i = 0; i < particles.length; i++) {
      particles[i].px = particles[i].x;
      particles[i].py = particles[i].y;
    }
    let guard = 0;
    while (remaining > 1e-5 && guard < 16) {
      let maxSpeed = 48;
      for (let i = 0; i < particles.length; i++) {
        const p = particles[i];
        if (p.delay > 0) continue;
        maxSpeed = Math.max(maxSpeed, Math.hypot(p.vx, p.vy));
      }
      const slice = Math.min(remaining, 2.4 / maxSpeed);
      integrate(particles, width, floor, gravity, slice);
      remaining -= slice;
      guard++;
    }
    return particles;
  }

  function integrate(particles, width, floor, gravity, step) {
    for (let i = 0; i < particles.length; i++) {
      const p = particles[i];
      if (p.delay > 0) {
        p.delay -= step;
        continue;
      }
      p.vx += gravity.x * step;
      p.vy += gravity.y * step;
      p.vx *= 0.999;
      p.vy *= 0.999;
      p.x += p.vx * step;
      p.y += p.vy * step;
      contain(p, width, floor, true);
    }
    for (let pass = 0; pass < 6; pass++) {
      separate(particles, width, floor);
      for (let i = 0; i < particles.length; i++) {
        const p = particles[i];
        if (p.delay > 0) continue;
        contain(p, width, floor, false);
      }
    }
  }

  function contain(p, width, floor, settle) {
    if (p.x - p.r < 0) {
      p.x = p.r;
      if (p.vx < 0) p.vx *= -0.28;
    } else if (p.x + p.r > width) {
      p.x = width - p.r;
      if (p.vx > 0) p.vx *= -0.28;
    }
    if (p.y - p.r < 0) {
      p.y = p.r;
      if (p.vy < 0) p.vy *= -0.2;
    }
    if (p.y + p.r > floor) {
      p.y = floor - p.r;
      if (p.vy > 0) p.vy = settle ? p.vy * -REST_FLOOR : 0;
      if (settle) p.vx *= FLOOR_GRIP;
      p.floor = 1;
    } else if (settle) {
      p.floor = 0;
    }
  }

  function separate(particles, width, floor) {
    const cell = 24;
    const bins = new Map();
    const key = (x, y) => x + "," + y;
    for (let i = 0; i < particles.length; i++) {
      const p = particles[i];
      if (p.delay > 0) continue;
      const ix = Math.floor(p.x / cell);
      const iy = Math.floor(p.y / cell);
      for (let oy = -1; oy <= 1; oy++) {
        for (let ox = -1; ox <= 1; ox++) {
          const bucket = bins.get(key(ix + ox, iy + oy));
          if (!bucket) continue;
          for (let n = 0; n < bucket.length; n++) resolve(particles[bucket[n]], p, width, floor);
        }
      }
      const id = key(ix, iy);
      let bucket = bins.get(id);
      if (!bucket) {
        bucket = [];
        bins.set(id, bucket);
      }
      bucket.push(i);
    }
  }

  function blocked(p, x, y, width, floor) {
    return x - p.r < 0 || x + p.r > width || y - p.r < 0 || y + p.r > floor;
  }

  function resolve(a, b, width, floor) {
    let dx = b.x - a.x;
    let dy = b.y - a.y;
    const min = a.r + b.r;
    let dist2 = dx * dx + dy * dy;
    if (dist2 >= min * min) return;
    if (dist2 < 1e-8) {
      dx = 0.01;
      dy = -0.02;
      dist2 = dx * dx + dy * dy;
    }
    const dist = Math.sqrt(dist2);
    const nx = dx / dist;
    const ny = dy / dist;
    const overlap = min - dist;
    const inv = 1 / (a.m + b.m);
    let ax = -nx * overlap * b.m * inv;
    let ay = -ny * overlap * b.m * inv;
    let bx = nx * overlap * a.m * inv;
    let by = ny * overlap * a.m * inv;
    if (blocked(a, a.x + ax, a.y + ay, width, floor)) {
      bx -= ax;
      by -= ay;
      ax = 0;
      ay = 0;
    }
    if (blocked(b, b.x + bx, b.y + by, width, floor)) {
      ax -= bx;
      ay -= by;
      bx = 0;
      by = 0;
    }
    a.x += ax;
    a.y += ay;
    b.x += bx;
    b.y += by;
    const rel = (b.vx - a.vx) * nx + (b.vy - a.vy) * ny;
    if (rel > 0) return;
    const impulse = -(1 + REST_DROP) * rel / (1 / a.m + 1 / b.m);
    a.vx -= impulse * nx / a.m;
    a.vy -= impulse * ny / a.m;
    b.vx += impulse * nx / b.m;
    b.vy += impulse * ny / b.m;
    const tx = -ny;
    const ty = nx;
    const tangent = (b.vx - a.vx) * tx + (b.vy - a.vy) * ty;
    const friction = tangent * 0.12;
    a.vx += friction * tx / a.m;
    a.vy += friction * ty / a.m;
    b.vx -= friction * tx / b.m;
    b.vy -= friction * ty / b.m;
  }

  function makeParticle(x, y, r, delay, vx, vy, glyph) {
    return {
      x: x,
      y: y,
      px: x,
      py: y,
      vx: vx,
      vy: vy,
      r: r,
      m: r * r,
      delay: delay,
      floor: 0,
      hue: Math.random(),
      glyph: glyph || 0
    };
  }

  let crowdHead = new Int32Array(8);
  let crowdNext = new Int32Array(8);

  function stepCrowd(particles, width, height, gravity, dt) {
    const step = Math.min(Math.max(dt, 0), 0.033);
    const floor = height;
    const cell = 8;
    const cols = Math.max(1, Math.ceil(width / cell));
    const rows = Math.max(1, Math.ceil(height / cell));
    const cells = cols * rows;
    if (crowdHead.length < cells) crowdHead = new Int32Array(cells);
    if (crowdNext.length < particles.length) crowdNext = new Int32Array(Math.max(particles.length, 64));
    crowdHead.fill(-1, 0, cells);
    for (let i = 0; i < particles.length; i++) {
      const p = particles[i];
      if (p.delay > 0) {
        p.delay -= step;
        continue;
      }
      p.px = p.x;
      p.py = p.y;
      p.vx += gravity.x * step;
      p.vy += gravity.y * step;
      const speed = Math.hypot(p.vx, p.vy);
      if (speed > 1500) {
        const scale = 1500 / speed;
        p.vx *= scale;
        p.vy *= scale;
      }
      p.x += p.vx * step;
      p.y += p.vy * step;
      contain(p, width, floor, true);
      let ix = Math.floor(p.x / cell);
      let iy = Math.floor(p.y / cell);
      if (ix < 0) ix = 0;
      else if (ix >= cols) ix = cols - 1;
      if (iy < 0) iy = 0;
      else if (iy >= rows) iy = rows - 1;
      const id = iy * cols + ix;
      crowdNext[i] = crowdHead[id];
      crowdHead[id] = i;
    }
    const packed = new Int32Array(12);
    for (let id = 0; id < cells; id++) {
      let count = 0;
      let j = crowdHead[id];
      let tail = -1;
      while (j !== -1 && count < 12) {
        packed[count++] = j;
        tail = j;
        j = crowdNext[j];
      }
      if (count > 6) {
        let bottom = 0;
        let onFloor = 0;
        for (let n = 0; n < count; n++) {
          const p = particles[packed[n]];
          if (p.y > bottom) bottom = p.y;
          if (p.floor) onFloor++;
        }
        if (onFloor > 0 || bottom > floor - 24) {
          for (let n = 0; n < count; n++) {
            const p = particles[packed[n]];
            const stacked = floor - p.r - n * p.r * 1.35;
            if (p.y > stacked) p.y = stacked;
            p.vy = Math.min(p.vy, 0);
          }
        } else {
          for (let n = 0; n < count; n++) {
            const p = particles[packed[n]];
            p.x += (n - count * 0.5) * 0.45;
            if (p.vy < 80) p.vy = 80;
          }
        }
        let extra = tail === -1 ? -1 : crowdNext[tail];
        while (extra !== -1) {
          const p = particles[extra];
          p.vx += extra & 1 ? 90 : -90;
          if (p.vy < 160) p.vy = 160;
          extra = crowdNext[extra];
        }
      } else {
        for (let a = 0; a < count; a++) {
          for (let b = a + 1; b < count; b++) crowdBump(particles[packed[a]], particles[packed[b]]);
        }
      }
    }
    for (let i = 0; i < particles.length; i++) {
      const p = particles[i];
      if (p.delay > 0) continue;
      contain(p, width, floor, false);
    }
    return particles;
  }

  function crowdBump(a, b) {
    let dx = b.x - a.x;
    let dy = b.y - a.y;
    const min = a.r + b.r;
    const dist2 = dx * dx + dy * dy;
    if (dist2 >= min * min || dist2 < 1e-6) return;
    const dist = Math.sqrt(dist2);
    const nx = dx / dist;
    const ny = dy / dist;
    const overlap = min - dist;
    if (a.floor && !b.floor) {
      b.x += nx * overlap;
      b.y += ny * overlap;
    } else if (b.floor && !a.floor) {
      a.x -= nx * overlap;
      a.y -= ny * overlap;
    } else {
      const half = overlap * 0.5;
      a.x -= nx * half;
      a.y -= ny * half;
      b.x += nx * half;
      b.y += ny * half;
    }
    const rel = (b.vx - a.vx) * nx + (b.vy - a.vy) * ny;
    if (rel < 0) {
      const push = -rel * 0.3;
      a.vx -= push * nx;
      a.vy -= push * ny;
      b.vx += push * nx;
      b.vy += push * ny;
    }
  }

  root.paperGIFSplashSim = {
    stepParticles: stepParticles,
    stepCrowd: stepCrowd,
    makeParticle: makeParticle
  };

  if (typeof document === "undefined") return;

  const GLYPHS = "OPRemote.:-=+*#%@";
  const CAP = 17000;
  const canvas = document.getElementById("sim");
  const wordCanvas = document.getElementById("word");
  const wordCtx = wordCanvas ? wordCanvas.getContext("2d") : null;
  const gl = canvas.getContext("webgl", { alpha: false, antialias: false });
  const particles = [];
  const sources = [];
  const gravity = { x: 0, y: 2800 };
  let shake = 0;
  let builtFor = "";
  let reuse = 0;
  let dpr = 1;
  let program = null;
  let glBuffer = null;
  let uRes = null;
  let uSize = null;
  let uCount = null;
  const scratch = new Float32Array(CAP * 3);

  root.paperGIFSplash = {
    setGravity: function (right, down, wobble) {
      gravity.x = right * 2600;
      gravity.y = 2400 + down * 1100;
      shake = Math.max(shake, Math.min(1.8, wobble || 0));
    }
  };

  function resize() {
    dpr = Math.min(root.devicePixelRatio || 1, 2);
    const width = root.innerWidth;
    const height = root.innerHeight;
    canvas.width = Math.max(1, Math.floor(width * dpr));
    canvas.height = Math.max(1, Math.floor(height * dpr));
    canvas.style.width = width + "px";
    canvas.style.height = height + "px";
    if (wordCanvas) {
      wordCanvas.width = canvas.width;
      wordCanvas.height = canvas.height;
      wordCanvas.style.width = width + "px";
      wordCanvas.style.height = height + "px";
    }
    if (gl) gl.viewport(0, 0, canvas.width, canvas.height);
    const key = width + "x" + height;
    if (key !== builtFor) {
      builtFor = key;
      particles.length = 0;
      sampleSources(width, height);
      if (gl) setupGL();
    }
    drawWord(width, height);
  }

  function sampleSources(width, height) {
    sources.length = 0;
    const off = document.createElement("canvas");
    off.width = Math.max(1, Math.floor(width));
    off.height = Math.max(1, Math.floor(height));
    const ink = off.getContext("2d", { willReadFrequently: true });
    ink.fillStyle = "#fff";
    ink.textAlign = "center";
    ink.textBaseline = "middle";
    const titleSize = Math.max(28, Math.min(width * 0.105, 68));
    ink.font = "600 " + titleSize + "px ui-monospace, SFMono-Regular, Menlo, monospace";
    ink.fillText("OP Remote", width * 0.5, height * 0.3);
    ink.font = "500 " + Math.max(11, titleSize * 0.28) + "px ui-monospace, SFMono-Regular, Menlo, monospace";
    ink.fillText("> BOOT", width * 0.5, height * 0.3 - titleSize * 0.95);
    const image = ink.getImageData(0, 0, off.width, off.height).data;
    for (let y = 2; y < off.height - 2; y += 2) {
      for (let x = 2; x < off.width - 2; x += 2) {
        if (image[(y * off.width + x) * 4 + 3] < 50) continue;
        const below = image[((y + 2) * off.width + x) * 4 + 3] < 50;
        if (below || ((x * 13 + y) % 5) === 0) sources.push(x, y);
      }
    }
    if (sources.length < 8) {
      for (let i = 0; i < 40; i++) sources.push(width * 0.2 + (i / 39) * width * 0.6, height * 0.3);
    }
  }

  function pickGlyph() {
    if (Math.random() < 0.62) return (Math.random() * 8) | 0;
    return 8 + ((Math.random() * (GLYPHS.length - 8)) | 0);
  }

  function emit(n) {
    const count = sources.length / 2;
    if (!count) return;
    const height = root.innerHeight;
    for (let i = 0; i < n; i++) {
      const s = ((Math.random() * count) | 0) * 2;
      const glyph = pickGlyph();
      const x = sources[s] + (Math.random() - 0.5) * 22;
      const y = sources[s + 1] + Math.random() * 6;
      const vx = (Math.random() - 0.5) * 90;
      const vy = 40 + Math.random() * 180;
      if (particles.length < CAP) {
        particles.push(makeParticle(x, y, 2.5 + Math.random() * 0.9, 0, vx, vy, glyph));
        continue;
      }
      const p = particles[reuse];
      reuse = (reuse + 17) % particles.length;
      if (!p.floor && p.y < height * 0.8) continue;
      p.x = x;
      p.y = y;
      p.vx = vx;
      p.vy = vy;
      p.floor = 0;
      p.glyph = glyph;
      p.delay = 0;
    }
  }

  function drawWord(width, height) {
    if (!wordCtx) return;
    wordCtx.setTransform(dpr, 0, 0, dpr, 0, 0);
    wordCtx.clearRect(0, 0, width, height);
    const titleSize = Math.max(28, Math.min(width * 0.105, 68));
    wordCtx.textAlign = "center";
    wordCtx.textBaseline = "middle";
    wordCtx.fillStyle = "rgba(216,255,220,0.94)";
    wordCtx.font = "600 " + titleSize + "px ui-monospace, SFMono-Regular, Menlo, monospace";
    wordCtx.fillText("OP Remote", width * 0.5, height * 0.3);
    wordCtx.fillStyle = "rgba(125,255,138,0.62)";
    wordCtx.font = "500 " + Math.max(11, titleSize * 0.28) + "px ui-monospace, SFMono-Regular, Menlo, monospace";
    wordCtx.fillText("> BOOT", width * 0.5, height * 0.3 - titleSize * 0.95);
  }

  function setupGL() {
    const vs = gl.createShader(gl.VERTEX_SHADER);
    gl.shaderSource(vs, "attribute vec2 aPos; attribute float aGlyph; uniform vec2 uRes; uniform float uSize; varying float vGlyph; void main() { vec2 clip = (aPos / uRes) * 2.0 - 1.0; clip.y = -clip.y; gl_Position = vec4(clip, 0.0, 1.0); gl_PointSize = uSize; vGlyph = aGlyph; }");
    gl.compileShader(vs);
    const fs = gl.createShader(gl.FRAGMENT_SHADER);
    gl.shaderSource(fs, "precision mediump float; uniform sampler2D uAtlas; uniform float uCount; varying float vGlyph; void main() { float g = floor(vGlyph + 0.5); vec2 uv = vec2((g + gl_PointCoord.x) / uCount, gl_PointCoord.y); vec4 tex = texture2D(uAtlas, uv); if (tex.a < 0.35) discard; float t = g / max(uCount - 1.0, 1.0); vec3 col = mix(vec3(0.07, 0.42, 0.20), vec3(0.91, 1.0, 0.91), t); gl_FragColor = vec4(col, tex.a); }");
    gl.compileShader(fs);
    program = gl.createProgram();
    gl.attachShader(program, vs);
    gl.attachShader(program, fs);
    gl.bindAttribLocation(program, 0, "aPos");
    gl.bindAttribLocation(program, 1, "aGlyph");
    gl.linkProgram(program);
    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
      program = null;
      return;
    }
    gl.useProgram(program);
    uRes = gl.getUniformLocation(program, "uRes");
    uSize = gl.getUniformLocation(program, "uSize");
    uCount = gl.getUniformLocation(program, "uCount");
    gl.uniform1i(gl.getUniformLocation(program, "uAtlas"), 0);
    gl.uniform1f(uCount, GLYPHS.length);
    glBuffer = gl.createBuffer();
    const cell = 64;
    const sheet = document.createElement("canvas");
    sheet.width = cell * GLYPHS.length;
    sheet.height = cell;
    const g = sheet.getContext("2d");
    g.clearRect(0, 0, sheet.width, sheet.height);
    g.fillStyle = "#fff";
    g.font = "700 50px ui-monospace, SFMono-Regular, Menlo, monospace";
    g.textAlign = "center";
    g.textBaseline = "middle";
    for (let i = 0; i < GLYPHS.length; i++) g.fillText(GLYPHS[i], cell * i + cell * 0.5, cell * 0.54);
    const texture = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, texture);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, sheet);
    gl.enable(gl.BLEND);
    gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
    gl.clearColor(2 / 255, 7 / 255, 4 / 255, 1);
  }

  function drawCharacters(width, height) {
    const n = particles.length;
    if (!gl || !program) return;
    for (let i = 0; i < n; i++) {
      const p = particles[i];
      scratch[i * 3] = p.x;
      scratch[i * 3 + 1] = p.y;
      scratch[i * 3 + 2] = p.glyph || 0;
    }
    gl.useProgram(program);
    gl.viewport(0, 0, canvas.width, canvas.height);
    gl.uniform2f(uRes, width, height);
    gl.uniform1f(uSize, 13 * dpr);
    gl.bindBuffer(gl.ARRAY_BUFFER, glBuffer);
    gl.bufferData(gl.ARRAY_BUFFER, scratch.subarray(0, n * 3), gl.DYNAMIC_DRAW);
    gl.enableVertexAttribArray(0);
    gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 12, 0);
    gl.enableVertexAttribArray(1);
    gl.vertexAttribPointer(1, 1, gl.FLOAT, false, 12, 8);
    gl.clear(gl.COLOR_BUFFER_BIT);
    if (n) gl.drawArrays(gl.POINTS, 0, n);
  }

  let last = 0;
  function frame(now) {
    const width = root.innerWidth;
    const height = root.innerHeight;
    const dt = Math.min(0.033, last ? (now - last) / 1000 : 0.016);
    last = now;
    emit(particles.length < CAP ? 700 : 80);
    const kick = shake > 0.04 ? (Math.random() - 0.5) * shake * 900 : 0;
    shake *= 0.9;
    stepCrowd(particles, width, height, { x: gravity.x + kick, y: gravity.y }, dt);
    drawCharacters(width, height);
    root.requestAnimationFrame(frame);
  }

  root.addEventListener("resize", resize);
  resize();
  root.requestAnimationFrame(frame);
})(typeof window !== "undefined" ? window : globalThis);
