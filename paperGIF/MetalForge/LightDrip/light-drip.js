"use strict";(()=>{var U={burn:{text:"BURN",topText:"",font:"Anton",weight:400,italic:!1,size:.12,x:0,y:.32,tracking:0,topSize:.27,mode:"glow",direction:"down",trail:2,letterGlow:1.8,curve:.9,flare:1.9,flareStart:.45,wave:.55,lean:0,speed:.9,blur:1.9,brightness:1.15,aberration:.2,cell:.013,bands:4,glow:.65,exposure:1.35,grain:.1,dust:.55,vignette:.85,color1:"#ffe9c2",color2:"#ff8f1a",color3:"#ff3a0f",color4:"#8c0a1c",textColor:"#fff6e8",background:"#0a0503"},noise:{text:"NOISE",topText:"MAKE SOME",font:"Unbounded",weight:900,italic:!1,size:.075,x:0,y:.34,tracking:0,topSize:.27,mode:"glow",direction:"down",trail:1.9,letterGlow:1.3,curve:.6,flare:1.4,flareStart:.55,wave:.6,lean:-.45,speed:1.1,blur:1.2,brightness:1.45,aberration:2,cell:.013,bands:4,glow:.7,exposure:1.6,grain:.11,dust:.2,vignette:.6,color1:"#f9ffe0",color2:"#c6ff1a",color3:"#ff2fa8",color4:"#5a1cff",textColor:"#ffffff",background:"#050505"},pixel:{text:"LEVEL UP",topText:"PRESS START",font:"Silkscreen",weight:700,italic:!1,size:.06,x:0,y:.3,tracking:0,topSize:.27,mode:"pixel",direction:"down",trail:1.8,letterGlow:1.4,curve:.7,flare:1.3,flareStart:.55,wave:.3,lean:0,speed:.8,blur:1.8,brightness:1.5,aberration:0,cell:.013,bands:4,glow:.5,exposure:1.5,grain:.05,dust:0,vignette:.5,color1:"#ffffff",color2:"#ffe600",color3:"#ff3b6b",color4:"#3b5bff",textColor:"#ffffff",background:"#07070c"},sketch:{text:"sketch",topText:"",font:"DM Serif Display",weight:400,italic:!1,size:.1,x:0,y:.33,tracking:0,topSize:.27,mode:"sketch",direction:"down",trail:1.8,letterGlow:1.4,curve:1,flare:1.2,flareStart:.55,wave:.7,lean:.15,speed:.4,blur:2.4,brightness:1.3,aberration:0,cell:.008,bands:4,glow:0,exposure:1.4,grain:.06,dust:0,vignette:.2,color1:"#ffffff",color2:"#3a3835",color3:"#55524d",color4:"#d0453a",textColor:"#22201c",background:"#f5f2ea"},heat:{text:"HEAT",topText:"SIGNATURE",font:"Bebas Neue",weight:400,italic:!1,size:.13,x:0,y:.32,tracking:0,topSize:.27,mode:"thermal",direction:"down",trail:1.8,letterGlow:1.3,curve:.85,flare:1.7,flareStart:.55,wave:.7,lean:0,speed:.5,blur:2.2,brightness:1.3,aberration:.2,cell:.013,bands:4,glow:.4,exposure:1.45,grain:.1,dust:0,vignette:.9,color1:"#ffffff",color2:"#ffe14a",color3:"#ff3d2e",color4:"#4a137e",textColor:"#ffffff",background:"#000004"},system:{text:"SYSTEM",topText:"> BOOT",font:"IBM Plex Mono",weight:700,italic:!1,size:.07,x:0,y:.3,tracking:0,topSize:.27,mode:"ascii",direction:"down",trail:1.8,letterGlow:1.3,curve:.85,flare:1.5,flareStart:.55,wave:.4,lean:0,speed:.5,blur:2.2,brightness:1.3,aberration:0,cell:.018,bands:4,glow:.6,exposure:1.45,grain:.06,dust:0,vignette:.9,color1:"#e9ffe9",color2:"#7dff8a",color3:"#24c45a",color4:"#0e5a2c",textColor:"#d8ffdc",background:"#020704"},groovy:{text:"groovy",topText:"",font:"Shrikhand",weight:400,italic:!1,size:.1,x:0,y:.3,tracking:0,topSize:.27,mode:"retro",direction:"down",trail:1.8,letterGlow:1.3,curve:.85,flare:1.6,flareStart:.55,wave:.45,lean:0,speed:.5,blur:2.2,brightness:1.3,aberration:0,cell:.013,bands:4,glow:0,exposure:1.45,grain:.05,dust:0,vignette:.2,color1:"#e8432e",color2:"#f28c28",color3:"#f6c445",color4:"#4e9a8a",textColor:"#3a2418",background:"#f4e6cc"}},he=["glow","pixel","sketch","thermal","ascii","retro"],Se=new Set(["sketch","retro"]),Ae=[["Anton","Anton"],["Unbounded","Unbounded:wght@400;700;900"],["Silkscreen","Silkscreen:wght@400;700"],["DM Serif Display","DM+Serif+Display:ital@0;1"],["Bebas Neue","Bebas+Neue"],["IBM Plex Mono","IBM+Plex+Mono:ital,wght@0,500;0,700;1,500"],["Shrikhand","Shrikhand"],["Inter","Inter:ital,wght@0,400;0,600;0,800;0,900;1,600"],["Poppins","Poppins:ital,wght@0,500;0,700;0,900;1,700"],["Playfair Display","Playfair+Display:ital,wght@0,400;0,700;1,400;1,700"],["Space Grotesk","Space+Grotesk:wght@300;500;700"],["Syne","Syne:wght@700;800"]],C={look:"burn",...U.burn,delay:1,growTime:2.6,loop:!1},ke=Object.keys(C).filter(i=>typeof C[i]=="number"),Me=Object.keys(C).filter(i=>typeof C[i]=="boolean");function _e(i,l){if(!(i in C)||l==null)return;if(ke.includes(i)){let t=Number(l);return Number.isFinite(t)?t:void 0}if(Me.includes(i))return l===!0||l==="true"||l===""||l==="1";let u=String(l);return i==="look"?u in U?u:void 0:i==="mode"?he.includes(u)?u:void 0:i==="direction"?u==="up"||u==="down"?u:void 0:/^(color\d|textColor|background)$/.test(i)?/^#[0-9a-f]{6}$/i.test(u)?u.toLowerCase():void 0:u.slice(0,40)}function pe(i){let l={};for(let[u,t]of Object.entries(i||{})){let s=_e(u,t);s!==void 0&&(l[u]=s)}return l}function Ce(){if(typeof document>"u"||document.getElementById("mf-lightdrip-fonts"))return;let i=document.createElement("link");i.id="mf-lightdrip-fonts",i.rel="stylesheet",i.href=`https://fonts.googleapis.com/css2?${Ae.map(l=>`family=${l[1]}`).join("&")}&display=swap`,document.head.appendChild(i)}var Le=`#version 300 es
in vec2 a; void main(){ gl_Position = vec4(a, 0., 1.); }`,De=`#version 300 es
precision highp float;
uniform vec2 uRes; uniform float uTime, uDpr;
uniform sampler2D uText, uProf, uField, uAscii;
uniform vec4 uRect; uniform vec2 uRows; uniform float uBase, uHalfW, uCx, uTrail, uNear, uShape, uReach;
uniform float uMode, uDir, uLines, uPix, uPaper;
uniform float uFlare, uLen, uWave, uLean, uBlur, uStreak, uAber, uGlow, uExposure, uGrain, uDust, uVig;
uniform vec3 uC0, uC1, uC2, uC3, uInk, uBg;
out vec4 o;

float h21(vec2 p){ p = fract(p*vec2(123.34, 456.21)); p += dot(p, p + 45.32); return fract(p.x*p.y); }
float vn(vec2 p){ vec2 i = floor(p), f = fract(p); f = f*f*(3. - 2.*f);
  return mix(mix(h21(i), h21(i + vec2(1,0)), f.x), mix(h21(i + vec2(0,1)), h21(i + 1.), f.x), f.y); }
float fbm(vec2 p){ float a = .5, s = 0.; for(int i = 0; i < 4; i++){ s += a*vn(p); p = p*2.03 + 17.1; a *= .5; } return s; }
vec3 pal(float t){ t = clamp(t, 0., 1.)*3.;
  if(t < 1.) return mix(uC0, uC1, t); if(t < 2.) return mix(uC1, uC2, t - 1.); return mix(uC2, uC3, t - 2.); }
float flareF(float d){ return 1. + uFlare*3.*pow(d/uLen, 2.4); }

void main(){
  vec2 q = vec2(gl_FragCoord.x, uRes.y - gl_FragCoord.y)/uRes.y;
  float asp = uRes.x/uRes.y, cx = uCx;
  float t = uTime;
  int md = int(uMode + .5);
  vec3 L = vec3(0.);
  float d = q.y - uBase;
  float yTop = uRect.y + uRows.x*uRect.w;
  float yBot = uRect.y + uRows.y*uRect.w;
  float capQ = max(yBot - yTop, .005);

  float dH = uDir > 0. ? d : yTop - q.y;
  float dd0 = max(dH, 0.);
  vec2 gp = vec2((q.x - cx)/(uHalfW*1.5 + dd0*flareF(dd0)*uHalfW*.9 + .05), (dH - .15)/.6);
  L += pal(.75)*.07*exp(-dot(gp, gp)*1.6)*smoothstep(0., .6, uReach);

  vec2 qq = q;
  float yc = (yTop + yBot)*.5;
  if(uDir < 0.) qq.y = 2.*yc - qq.y;
  float baseD = uDir > 0. ? uBase : yBot;
  vec2 cellUV = vec2(.5);
  if(md == 1){ cellUV = fract(qq/uPix); qq = (floor(qq/uPix) + .5)*uPix; }
  if(md == 4){ vec2 cs = vec2(uPix*.62, uPix); cellUV = fract(qq/cs); qq = (floor(qq/cs) + .5)*cs; }
  vec3 mulC = vec3(1.), paperCol = uBg, dirC = vec3(0.); float dirA = 0.;

  if(qq.y > yTop){
    float dd = max(qq.y - baseD, 0.);
    float f = flareF(dd);
    float xs0 = (qq.x - cx - uLean*dd*dd)/f;
    float wv = (fbm(vec2(xs0*7., dd*2.2 - t*.35)) - .5)*uWave*.13*smoothstep(0., .22, dd);
    vec3 x = vec3(qq.x - wv*f) + vec3(1., 0., -1.)*uAber*(.0012 + .02*dd)*f;
    float y = qq.y;
    vec3 acc = vec3(0.); float hot = 0., xh = 0., ah = 0.;
    float A = 3.*uFlare;
    float c0 = capQ*.25, lc = log(c0), du = .26;
    float e0 = y - yBot;
    float v = e0 > 0. ? log(e0 + c0) : lc + e0/c0;
    float vN = floor(v/du)*du; if(vN > v - 1e-5) vN -= du;
    for(int i = 0; i < 90; i++){
      float yN = vN >= lc ? exp(vN) - c0 + yBot : yBot + (vN - lc)*c0;
      float dy = y - yN;
      float ys = uDir > 0. ? y : 2.*yc - y;
      float trav = qq.y - y;
      float rk = uReach*(.8 + .4*vn(vec2(x.g*28., 3.7)));
      float grow = smoothstep(rk, rk - .07, trav);
      float lod = uBlur*.35 + min(trav/capQ*.22, 2.6);
      vec4 F = textureLod(uField, (vec2(x.g, ys) - uRect.xy)/uRect.zw, lod);
      float ar = textureLod(uField, (vec2(x.r, ys) - uRect.xy)/uRect.zw, lod).b;
      float ab = textureLod(uField, (vec2(x.b, ys) - uRect.xy)/uRect.zw, lod).b;
      float wgt = dy/capQ*(1. + uNear*exp(-trav/capQ*.9))*grow;
      acc += vec3(ar, F.b, ab)*wgt;
      hot += F.b*dy/capQ*exp(-trav/capQ*2.5)*grow;
      xh += F.b*wgt*x.g; ah += F.b*wgt;
      float dep = max(y - baseD, 0.), n1 = dep/uLen;
      float slope = A*2.4*pow(n1, 1.4)/uLen/(1. + A*pow(n1, 2.4));
      vec3 vx = (x - cx - uLean*dep*dep)*slope + 2.*uLean*dep;
      vx += uShape*(F.r*2. - 1.)*(1. - F.b);
      x -= vx*dy; y = yN; vN -= du;
      if(y < yTop) break;
    }
    vec3 s = acc*uTrail*.55;
    float xc = ah > .001 ? (xh/ah - cx) : xs0*f;
    float flow = .62 + .76*fbm(vec2(xc*45., dd*6. - t*1.3));
    float fade = pow(f, -.28);
    float side = clamp(abs(xc)/max(uHalfW, .01), 0., 1.2);
    float n = fbm(vec2(xc/max(uHalfW, .01)*2.2 + 3., dd*1.2 - t*.12));
    float h = clamp(.3 + .4*side + .85*(n - .45) + .3*(1. - min(s.g, 1.)) + .2*dd - .3*exp(-dd/capQ*1.2), 0., 1.);
    vec3 sc = pow(min(s, vec3(1.8)), vec3(1.6));
    float wk = 1.;
    if(md == 0){
      L += pal(h)*sc*uStreak*flow*fade*1.05;
    } else if(md == 1){
      vec3 pc = floor(sc*uStreak*flow*fade*4. + .5)/4.;
      float gap = step(.13, cellUV.x)*step(.13, cellUV.y);
      L += pal(floor(h*5.)/4.)*pc*gap*1.15;
      L += uC0*floor(min(hot, 1.)*4. + .5)/4.*gap*.9;
      wk = 0.;
    } else if(md == 2){
      float v = clamp(s.g*uStreak*.8*fade, 0., 1.6);
      float wob = (vn(q*vec2(70., 9.)) - .5)*.35;
      vec2 D1 = vec2(.7071, .7071), D2 = vec2(.7071, -.7071);
      float p1 = dot(q, D1)/uPix + wob, p2 = dot(q, D2)/uPix - wob, p3 = q.x/(uPix*.8) + wob*.6;
      float w1 = clamp((v - .1)*.4, 0., .3), w2 = clamp((v - .42)*.4, 0., .3), w3 = clamp((v - .8)*.45, 0., .3);
      float h1 = smoothstep(w1 + fwidth(p1), w1 - fwidth(p1), abs(fract(p1) - .5))*smoothstep(0., .03, w1);
      float h2 = smoothstep(w2 + fwidth(p2), w2 - fwidth(p2), abs(fract(p2) - .5))*smoothstep(0., .03, w2);
      float h3 = smoothstep(w3 + fwidth(p3), w3 - fwidth(p3), abs(fract(p3) - .5))*smoothstep(0., .03, w3);
      mulC *= mix(vec3(1.), uC1, h1*.85);
      mulC *= mix(vec3(1.), uC2, h2*.85);
      mulC *= mix(vec3(1.), uC3, h3*.9);
    } else if(md == 3){
      float v = clamp(s.g*uStreak*.55*fade, 0., 1.);
      v = floor(v*18.)/18.;
      dirC = pal(1. - v)*(.88 + .12*sin(gl_FragCoord.y*1.6));
      dirA = smoothstep(0., .06, v);
      wk = 0.;
    } else if(md == 4){
      float v = clamp(s.g*uStreak*.6*fade, 0., .999);
      float gi = floor(v*10.);
      float gl = texture(uAscii, vec2((gi + clamp(cellUV.x, .02, .98))/10., cellUV.y)).r;
      L += pal(h)*gl*(.4 + .9*v)*1.4;
      L += uC0*gl*min(hot, 1.)*1.2;
      wk = .15;
    } else {
      float N = max(uLines, 2.);
      float v = s.g*uStreak*.7*fade, fw = max(fwidth(v), 1e-4);
      float m = smoothstep(.14 - fw, .14 + fw, v);
      float b = clamp(abs(xc)/max(uHalfW, .01), 0., .999)*N;
      float fb = fract(b), fwb = max(fwidth(b), 1e-4);
      float sep = smoothstep(0., fwb*1.5, fb)*smoothstep(1., 1. - fwb*1.5, fb);
      paperCol = mix(paperCol, pal(floor(b)/(N - 1.)), m*mix(1., sep, .9));
    }
    float wide = textureLod(uProf, vec2(.5 + (xs0 + wv)/uRect.z, .5), uBlur + dd*5. + 2.5).r;
    L += pal(clamp(h + .2, 0., 1.))*wide*.3*wk*fade*smoothstep(-.01, .03, qq.y - baseD)*smoothstep(uReach, uReach - .15, dd);
    L += uC0*hot*.7*(md == 1 || md == 4 ? 0. : 1.);
  }

  vec2 tuv = (q - uRect.xy)/uRect.zw;
  float ab = uAber*.0012;
  vec3 ta = vec3(texture(uText, tuv + vec2(ab, 0.)).a, texture(uText, tuv).a, texture(uText, tuv - vec2(ab, 0.)).a);
  float g1 = textureLod(uText, tuv, 3.5).a, g2 = textureLod(uText, tuv, 5.).a, g3 = textureLod(uText, tuv, 6.5).a;
  float textA = ta.g;
  L += uInk*ta*2.2;
  L += mix(uInk, pal(.35), .45)*(g1*.5 + g2*.8 + g3*1.1)*uGlow*(.45 + .55*smoothstep(0., .3, uReach));

  vec3 col = 1. - exp(-L*uExposure);
  col = uBg + (1. - uBg)*col;
  col = mix(col, dirC, clamp(dirA, 0., 1.));
  if(dirA > 0.) col = mix(col, uInk, clamp(textA, 0., 1.)*dirA);
  if(uPaper > .5){ col = paperCol*mulC; col = mix(col, uInk, clamp(textA, 0., 1.)); }

  vec2 vc = (q - vec2(asp*.5, .5))/vec2(asp, 1.);
  col *= 1. - uVig*dot(vc, vc)*1.1;

  vec2 px = gl_FragCoord.xy/uDpr;
  float sp = step(1. - .0009*uDust, h21(floor(px/1.5)));
  float scr = smoothstep(.985, 1., vn(vec2(px.x*.004 + px.y*.03, px.y*.004)*vec2(1., 9.)))*step(.72, vn(px*.006));
  col += vec3(.55)*(sp + scr*.35)*uDust;
  col += (h21(px + fract(t*7.13)*311.) - .5)*uGrain*(.6 + .4*col);
  o = vec4(clamp(col, 0., 1.), 1.);
}`,v=2048,P=512,q=Math.round(P*.62),K=200,Pe=" .:-=+*#%@";function me(i,l,u,t){let s=i,e=new Float32Array(l*u);for(let R=0;R<3;R++){for(let x=0;x<u;x++){let S=0,n=x*l;for(let w=-t;w<=t;w++)S+=s[n+Math.min(l-1,Math.max(0,w))];for(let w=0;w<l;w++)e[n+w]=S/(2*t+1),S+=s[n+Math.min(l-1,w+t+1)]-s[n+Math.max(0,w-t)]}for(let x=0;x<l;x++){let S=0;for(let n=-t;n<=t;n++)S+=e[Math.min(u-1,Math.max(0,n))*l+x];for(let n=0;n<u;n++)s[n*l+x]=S/(2*t+1),S+=e[Math.min(u-1,n+t+1)*l+x]-e[Math.max(0,n-t)*l+x]}}return s}var ee=i=>i<.5?4*i*i*i:1-Math.pow(-2*i+2,3)/2,G=i=>[1,3,5].map(l=>parseInt(i.slice(l,l+2),16)/255);function te(i,l,u={}){Ce();let t={...C};{let o=pe(l);o.look&&o.look!==t.look&&(t={...t,...U[o.look]}),Object.assign(t,o)}let s=document.createElement("canvas");s.style.cssText="position:absolute;left:0;top:0;width:100%;height:100%;display:block",i.appendChild(s);let e=s.getContext("webgl2",{antialias:!1,alpha:!1,preserveDrawingBuffer:!0});if(!e){let o=document.createElement("div");return o.textContent="This browser cannot draw WebGL2.",o.style.cssText="position:absolute;inset:0;display:grid;place-items:center;color:#888;font:14px system-ui",i.appendChild(o),{ok:!1,canvas:s,set(){},replay(){},dispose(){s.remove(),o.remove()},debug:{}}}let R=(o,a)=>{let r=e.createShader(o);if(e.shaderSource(r,a),e.compileShader(r),!e.getShaderParameter(r,e.COMPILE_STATUS))throw new Error(e.getShaderInfoLog(r));return r},x=e.createProgram();if(e.attachShader(x,R(e.VERTEX_SHADER,Le)),e.attachShader(x,R(e.FRAGMENT_SHADER,De)),e.bindAttribLocation(x,0,"a"),e.linkProgram(x),!e.getProgramParameter(x,e.LINK_STATUS))throw new Error(e.getProgramInfoLog(x));e.useProgram(x);let S=e.createBuffer();e.bindBuffer(e.ARRAY_BUFFER,S),e.bufferData(e.ARRAY_BUFFER,new Float32Array([-1,-1,3,-1,-1,3]),e.STATIC_DRAW),e.enableVertexAttribArray(0),e.vertexAttribPointer(0,2,e.FLOAT,!1,0,0);let n={};for(let o=0,a=e.getProgramParameter(x,e.ACTIVE_UNIFORMS);o<a;o++){let r=e.getActiveUniform(x,o).name;n[r]=e.getUniformLocation(x,r)}let w=o=>{let a=e.createTexture();return e.activeTexture(e.TEXTURE0+o),e.bindTexture(e.TEXTURE_2D,a),e.texParameteri(e.TEXTURE_2D,e.TEXTURE_MIN_FILTER,e.LINEAR_MIPMAP_LINEAR),e.texParameteri(e.TEXTURE_2D,e.TEXTURE_MAG_FILTER,e.LINEAR),e.texParameteri(e.TEXTURE_2D,e.TEXTURE_WRAP_S,e.CLAMP_TO_EDGE),e.texParameteri(e.TEXTURE_2D,e.TEXTURE_WRAP_T,e.CLAMP_TO_EDGE),a},xe=w(0),ge=w(1),ve=w(2),we=w(3);e.uniform1i(n.uText,0),e.uniform1i(n.uProf,1),e.uniform1i(n.uField,2),e.uniform1i(n.uAscii,3);let W=document.createElement("canvas");W.width=v,W.height=P;let d=W.getContext("2d",{willReadFrequently:!0}),A={capPx:140,wordW:400,rows:[.33,.63]},X=!1,L=(o,a=t.weight,r=t.italic&&X)=>`${r?"italic ":""}${a} ${o}px "${t.font}", "Helvetica Neue", Helvetica, Arial, sans-serif`,be=-.21;function H(o,a){if(!a)return d.measureText(o).width;let r=0;for(let c of o)r+=d.measureText(c).width;return r+a*Math.max(0,[...o].length-1)}function ae(o,a,r,c){let f=t.italic&&!X;if(f&&(d.save(),d.translate(0,r),d.transform(1,0,be,1,0,0),r=0),!c)d.textAlign="center",d.fillText(o,a,r);else{d.textAlign="left";let h=a-H(o,c)/2;for(let T of o)d.fillText(T,h,r),h+=d.measureText(T).width+c}f&&d.restore()}function Te(o,a){let r=v/2,c=P/2,f=new Float32Array(r*c);for(let m=0;m<c;m++)for(let y=0;y<r;y++){let g=(m*2*v+y*2)*4+3;f[m*r+y]=(o[g]+o[g+4]+o[g+v*4]+o[g+v*4+4])/1020}let h=me(Float32Array.from(f),r,c,Math.max(3,Math.round(a*.09))),T=me(Float32Array.from(f),r,c,1),b=new Float32Array(r*c),p=new Float32Array(r*c),D=1e-6;for(let m=1;m<c-1;m++)for(let y=1;y<r-1;y++){let g=m*r+y;b[g]=-(h[g+1]-h[g-1])/2,p[g]=-(h[g+r]-h[g-r])/2,D=Math.max(D,Math.hypot(b[g],p[g]))}let M=new Uint8Array(r*c*4);for(let m=0;m<r*c;m++){let y=Math.hypot(b[m],p[m]),g=1/(y+.2*D);M[m*4]=Math.round(Math.max(-1,Math.min(1,b[m]*g))*127.5+127.5),M[m*4+1]=Math.round(Math.max(-1,Math.min(1,p[m]*g))*127.5+127.5),M[m*4+2]=Math.round(Math.min(1,T[m])*255),M[m*4+3]=255}e.activeTexture(e.TEXTURE2),e.bindTexture(e.TEXTURE_2D,ve),e.pixelStorei(e.UNPACK_ALIGNMENT,1),e.texImage2D(e.TEXTURE_2D,0,e.RGBA,r,c,0,e.RGBA,e.UNSIGNED_BYTE,M),e.generateMipmap(e.TEXTURE_2D)}function ie(){d.clearRect(0,0,v,P),d.fillStyle="#fff",d.textBaseline="alphabetic";let o=String(t.text||" ");if(t.italic){let E="Hamburgefonstiv 0123";d.font=L(K,t.weight,!1);let _=d.measureText(E).width;d.font=L(K,t.weight,!0),X=Math.abs(d.measureText(E).width-_)>.5}else X=!1;let a=K;d.font=L(a);let r=(t.tracking||0)*a,c=H(o,r);c>v*.88&&(a=Math.max(8,Math.floor(a*v*.88/c))),d.font=L(a);let f=(t.tracking||0)*a,h=d.measureText("H").actualBoundingBoxAscent||a*.72,T=d.measureText(o),b=H(o,f),p=[(q-(T.actualBoundingBoxAscent||h))/P,(q+(T.actualBoundingBoxDescent||0)+1)/P];if(ae(o,v/2,q,f),Te(d.getImageData(0,0,v,P).data,h),t.topText){let E=Math.min(t.weight,700),_=Math.max(6,Math.round(a*t.topSize));d.font=L(_,E);let I=H(String(t.topText),f*t.topSize);I>v*.9&&(_=Math.max(6,Math.floor(_*v*.9/I)),d.font=L(_,E)),ae(String(t.topText),v/2,q-h-a*.09,f*t.topSize)}A={capPx:h,wordW:b,rows:p},e.activeTexture(e.TEXTURE0),e.bindTexture(e.TEXTURE_2D,xe),e.pixelStorei(e.UNPACK_PREMULTIPLY_ALPHA_WEBGL,!1),e.texImage2D(e.TEXTURE_2D,0,e.RGBA,e.RGBA,e.UNSIGNED_BYTE,W),e.generateMipmap(e.TEXTURE_2D);let D=Math.max(4,Math.round(h*.34)),M=q-D,m=D+3,y=d.getImageData(0,M,v,m).data,g=new Uint8Array(v);for(let E=0;E<v;E++){let _=0;for(let I=0;I<m;I++)_+=y[(I*v+E)*4+3];g[E]=Math.min(255,Math.round(_/(m*.55)))}e.activeTexture(e.TEXTURE1),e.bindTexture(e.TEXTURE_2D,ge),e.pixelStorei(e.UNPACK_ALIGNMENT,1),e.texImage2D(e.TEXTURE_2D,0,e.R8,v,1,0,e.RED,e.UNSIGNED_BYTE,g),e.generateMipmap(e.TEXTURE_2D),k=!0}function ne(){let r=document.createElement("canvas");r.width=400,r.height=64;let c=r.getContext("2d");c.fillStyle="#fff",c.textAlign="center",c.textBaseline="middle",c.font=`700 ${64*.78}px "IBM Plex Mono", Menlo, monospace`;for(let f=0;f<10;f++)c.fillText(Pe[f],40*f+40/2,64*.54);e.activeTexture(e.TEXTURE3),e.bindTexture(e.TEXTURE_2D,we),e.texImage2D(e.TEXTURE_2D,0,e.RGBA,e.RGBA,e.UNSIGNED_BYTE,r),e.generateMipmap(e.TEXTURE_2D)}let ye=["text","topText","font","weight","italic","tracking","topSize"],le=0,F={pending:0};function ce(){let o=++le;if(ie(),typeof document>"u"||!document.fonts)return;F.pending++;let a=new Promise(r=>setTimeout(r,4e3));Promise.race([Promise.all([document.fonts.load(L(K)),document.fonts.load(L(60,Math.min(t.weight,700)))]),a]).catch(()=>{}).then(()=>{F.pending--,o===le&&!N&&ie()})}typeof document<"u"&&document.fonts&&(F.pending++,Promise.race([document.fonts.load('700 40px "IBM Plex Mono"'),new Promise(o=>setTimeout(o,4e3))]).catch(()=>{}).then(()=>{F.pending--,N||(ne(),k=!0)})),ne();let N=!1,J=!1,k=!0,se=!0,O=0,V=0,B=0,z=performance.now(),Y=1;function fe(o){let a=t.delay,r=Math.max(.05,t.growTime),c=1.25;if(o<a)return 0;if(!t.loop){let p=(o-a)/r;return p>=1?6:ee(p)*c}let f=4.5,h=r*.7,T=1.2,b=(o-a)%(r+f+h+T);return b<r?ee(b/r)*c:b<r+f?6:b<r+f+h?(1-ee((b-r-f)/h))*c:0}function Ee(){Y=Math.min(typeof window<"u"&&window.devicePixelRatio||1,u.maxDpr||1.5);let o=Math.max(1,Math.round(i.clientWidth*Y)),a=Math.max(1,Math.round(i.clientHeight*Y));(s.width!==o||s.height!==a)&&(s.width=o,s.height=a,k=!0)}function Z(){Ee();let o=s.width,a=s.height,r=o/a;e.viewport(0,0,o,a);let c=r/2+t.x*r/2,f=t.size/A.capPx,h=r*.96;A.wordW*f>h&&(f=h/A.wordW);let T=v*f,b=P*f;e.uniform4f(n.uRect,c-T/2,t.y-q*f,T,b),e.uniform2f(n.uRows,A.rows[0],A.rows[1]),e.uniform1f(n.uBase,t.y),e.uniform1f(n.uCx,c),e.uniform1f(n.uHalfW,A.wordW*f/2),e.uniform2f(n.uRes,o,a),e.uniform1f(n.uTime,V*t.speed),e.uniform1f(n.uDpr,Y),e.uniform1f(n.uReach,fe(B)),e.uniform1f(n.uMode,Math.max(0,he.indexOf(t.mode))),e.uniform1f(n.uDir,t.direction==="up"?-1:1),e.uniform1f(n.uLines,t.bands),e.uniform1f(n.uPix,t.cell),e.uniform1f(n.uPaper,Se.has(t.mode)?1:0);let p=(D,M)=>e.uniform1f(n[M],t[D]);p("trail","uTrail"),p("letterGlow","uNear"),p("curve","uShape"),p("flare","uFlare"),p("flareStart","uLen"),p("wave","uWave"),p("lean","uLean"),p("blur","uBlur"),p("brightness","uStreak"),p("aberration","uAber"),p("glow","uGlow"),p("exposure","uExposure"),p("grain","uGrain"),p("dust","uDust"),p("vignette","uVig"),e.uniform3fv(n.uC0,G(t.color1)),e.uniform3fv(n.uC1,G(t.color2)),e.uniform3fv(n.uC2,G(t.color3)),e.uniform3fv(n.uC3,G(t.color4)),e.uniform3fv(n.uInk,G(t.textColor)),e.uniform3fv(n.uBg,G(t.background)),e.drawArrays(e.TRIANGLES,0,3),k=!1}let ue=!1;function Re(o){if(O=0,N)return;let a=Math.min(.05,(o-z)/1e3);z=o,J||(V+=a,B+=a),(!J||k)&&Z(),!ue&&!F.pending&&(ue=!0,u.onReady&&u.onReady()),j()}function j(){N||O||!se||typeof document<"u"&&document.hidden||(O=requestAnimationFrame(Re))}let de=()=>{z=performance.now(),j()};document.addEventListener("visibilitychange",de);let $=typeof IntersectionObserver<"u"?new IntersectionObserver(o=>{se=o.some(a=>a.isIntersecting),z=performance.now(),j()}):null;$&&$.observe(i);let Q=typeof ResizeObserver<"u"?new ResizeObserver(()=>k=!0):null;return Q&&Q.observe(i),s.addEventListener("webglcontextlost",o=>{o.preventDefault(),N=!0,cancelAnimationFrame(O)}),ce(),Z(),j(),{ok:!0,canvas:s,set(o){let a=pe(o),r=t;a.look&&a.look!==t.look&&(r={...t,...U[a.look]}),r={...r,...a};let c=ye.some(h=>r[h]!==t[h]),f=r.look!==t.look;t=r,c&&ce(),f&&(B=0),k=!0},replay(){B=0,k=!0},values:()=>({...t}),dispose(){N=!0,cancelAnimationFrame(O),document.removeEventListener("visibilitychange",de),$&&$.disconnect(),Q&&Q.disconnect();let o=e.getExtension("WEBGL_lose_context");o&&o.loseContext(),s.remove()},debug:{get pending(){return F.pending},freeze(o=!0){J=o,z=performance.now()},at(o,a=o){B=o,V=a,k=!0},render:Z,state:()=>({tl:B,clock:V,reach:fe(B),rows:A.rows,wordW:A.wordW})}}}var Ue=Object.keys(C),oe=Object.fromEntries(Ue.map(i=>[i.toLowerCase(),i])),re=class extends HTMLElement{static get observedAttributes(){return Object.keys(oe)}constructor(){super(),this._g=null,this._host=null,this._pending={}}connectedCallback(){if(this._g||this._booting)return;this._booting=!0,this.style.display||(this.style.display="block"),this.style.position||(this.style.position="relative");let l=()=>{if(this._booting=!1,!this.isConnected||this._g)return;this.clientHeight<2&&(this.style.height="min(90vh, 720px)");let u=document.createElement("div");u.style.cssText="position:absolute;left:0;top:0;right:0;bottom:0;overflow:hidden;border-radius:inherit",this.appendChild(u),this._host=u;let t={},s=this.getAttribute("look");s&&U[s]&&Object.assign(t,{look:s},U[s]);for(let e of this.getAttributeNames()){let R=oe[e];R&&R!=="look"&&(t[R]=this.getAttribute(e))}Object.assign(t,this._pending),this._pending={},this._g=te(u,t,{onReady:()=>this.dispatchEvent(new CustomEvent("ready"))})};document.readyState==="complete"?setTimeout(l,0):window.addEventListener("load",()=>setTimeout(l,0),{once:!0})}disconnectedCallback(){this._g&&(this._g.dispose(),this._g=null,this._host&&this._host.remove(),this._host=null)}attributeChangedCallback(l,u,t){let s=oe[l];s&&this.set({[s]:t})}set(l){this._g?this._g.set(l):Object.assign(this._pending,l)}replay(){this._g&&this._g.replay()}};typeof customElements<"u"&&!customElements.get("light-drip")&&customElements.define("light-drip",re);globalThis.MFLightDrip={DEFAULTS:C,STYLES:U,createLightDrip:te};if(typeof document<"u"&&document.currentScript){let i=()=>{if(!document.querySelector("light-drip")){let l=document.createElement("light-drip");l.style.cssText="display:block;position:relative;width:100%;height:100vh",document.body.appendChild(l)}};document.readyState==="loading"?document.addEventListener("DOMContentLoaded",i,{once:!0}):i()}})();

;Object.assign(MFLightDrip.DEFAULTS,{"look":"system","text":"OP Remote","topText":"> BOOT","font":"IBM Plex Mono","weight":600,"size":0.07,"y":0.3,"mode":"ascii","trail":1.8,"brightness":1.3,"letterGlow":0.7,"curve":2.15,"flare":0,"flareStart":0.3,"wave":0.65,"blur":2.2,"aberration":1.65,"cell":0.011,"delay":2,"growTime":3.1,"speed":0.5,"color1":"#e9ffe9","color2":"#7dff8a","color3":"#24c45a","color4":"#0e5a2c","textColor":"#d8ffdc","background":"#020704","glow":0.6,"exposure":1.45,"grain":0.15,"dust":0.05,"vignette":1.15});
