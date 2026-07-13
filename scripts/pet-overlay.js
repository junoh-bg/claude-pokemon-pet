#!/usr/bin/env osascript -l JavaScript
// claude-pokemon-pet overlay: a borderless, click-through, always-on-top
// window with an animated Pokémon that reacts to Claude Code session state.
// A pure view: all game state (species, level, EXP, localized names/moves)
// comes from resolved.json, written by pet-core.sh. The overlay keeps only
// presentation logic: animation, mood decay by age, evolution cutscene.
// ⌥-drag to move. Usage: pet-overlay.js <plugin-root>

ObjC.import('Cocoa');
ObjC.import('QuartzCore');

function run(argv) {
  var HOME = ObjC.unwrap($.NSHomeDirectory());
  var ROOT = (argv && argv[0]) || HOME + '/.claude/plugins/marketplaces/claude-pokemon-pet';
  var CACHE = HOME + '/.cache/claude-pokemon-pet';
  var SPRITES = CACHE + '/sprites-big';
  var POSF = CACHE + '/pos';
  var BOTTOM_OFFSET = 30;        // default home: just above the tmux bar
  var ROAM = 240;                // wander range while working (px)

  function readFile(p) {
    var s = $.NSString.stringWithContentsOfFileEncodingError($(p), $.NSUTF8StringEncoding, null);
    return (!s || s.isNil()) ? '' : ObjC.unwrap(s).trim();
  }
  function writeFile(p, text) {
    $(text).writeToFileAtomicallyEncodingError($(p), true, $.NSUTF8StringEncoding, null);
  }
  function josa(w, withFinal, noFinal) { // e.g. josa(name, '은', '는')
    var c = w.charCodeAt(w.length - 1);
    var hasFinal = c >= 0xAC00 && c <= 0xD7A3 && (c - 0xAC00) % 28 > 0;
    return w + (hasFinal ? withFinal : noFinal);
  }

  function todayStr() {
    var d = new Date();
    return d.getFullYear() + '-' +
      ('0' + (d.getMonth() + 1)).slice(-2) + '-' + ('0' + d.getDate()).slice(-2);
  }

  // resolved.json is only rewritten on session events, so after midnight it
  // holds yesterday's level/stage until something fires. When the stamp goes
  // stale, ask the core to re-resolve (at most once a minute) — the game
  // logic stays in pet-core.sh; the overlay just picks up the fresh file.
  var lastKick = 0;
  function kickResolve() {
    if (Date.now() - lastKick < 60000) return;
    lastKick = Date.now();
    try {
      var t = $.NSTask.alloc.init;
      t.setLaunchPath('/bin/bash');
      t.setArguments($([ROOT + '/scripts/pet-core.sh', 'resolve']));
      t.setStandardOutput($.NSFileHandle.fileHandleWithNullDevice);
      t.setStandardError($.NSFileHandle.fileHandleWithNullDevice);
      t.launch;
    } catch (e) {}
  }

  // Pure view of resolved.json (written by pet-core.sh). The only session
  // logic kept here is presentation: mood decay by age of the last event.
  function petState() {
    var r;
    try { r = JSON.parse(readFile(CACHE + '/resolved.json')); } catch (e) { return null; }
    if (!r || !r.species) return null;
    if (r.date && r.date !== todayStr()) kickResolve();
    var age = Math.floor(Date.now() / 1000) - (r.state_ts || 0);
    var state = r.state || 'idle';
    if ((state === 'done' || state === 'hello') && age > 45) state = 'idle';
    if ((state === 'thinking' || state === 'working' || state === 'waiting') && age > 600) state = 'idle';
    r.state = state;
    r.age = age;
    return r;
  }

  // Battle-log captions; rotates every 7s within a state. Templates are
  // presentation; p.name and p.moves arrive already localized from the core.
  function pick(arr) { return arr[Math.floor(Date.now() / 7000) % arr.length]; }
  function moodText(p) {
    var move = pick(p.moves && p.moves.length ? p.moves : ['TACKLE']);
    var N = p.name;
    if (p.lang === 'ko') {
      switch (p.state) {
        case 'thinking': return pick([josa(N, '은', '는') + ' 기합을 넣고 있다!', josa(N, '은', '는') + ' 상황을 살피고 있다!']);
        case 'working':  return N + '의 ' + move + '!';
        case 'done':     return pick(['효과는 굉장했다!', josa(N, '은', '는') + ' 경험치를 얻었다!']);
        case 'waiting':  return josa(N, '은', '는') + ' 지시를 기다리고 있다';
        case 'hello':    return '가라! ' + N + '!';
        default:         return josa(N, '은', '는') + ' 쿨쿨 잠들어 있다';
      }
    }
    switch (p.state) {
      case 'thinking': return pick([N + ' is getting pumped!', N + ' is sizing up the task!']);
      case 'working':  return N + ' used ' + move + '!';
      case 'done':     return pick(["It's super effective!", N + ' gained EXP. Points!']);
      case 'waiting':  return N + ' looks at you expectantly';
      case 'hello':    return 'Go! ' + N + '!';
      default:         return N + ' is fast asleep';
    }
  }

  // ── Window ──
  $.NSApplication.sharedApplication;
  $.NSApp.setActivationPolicy($.NSApplicationActivationPolicyAccessory);

  var winW = 224, winH = 250;
  var mouse = $.NSEvent.mouseLocation;
  var screens = $.NSScreen.screens;
  var screen = screens.objectAtIndex(0);
  for (var s = 0; s < screens.count; s++) {
    var scr = screens.objectAtIndex(s), sf = scr.frame;
    if (mouse.x >= sf.origin.x && mouse.x <= sf.origin.x + sf.size.width &&
        mouse.y >= sf.origin.y && mouse.y <= sf.origin.y + sf.size.height) { screen = scr; break; }
  }
  var vf = screen.visibleFrame;
  var homeX = vf.origin.x + vf.size.width - winW - 24;
  var homeY = vf.origin.y + BOTTOM_OFFSET;

  // Restore a dragged position if it is still on some screen
  var saved = readFile(POSF).split(/\s+/);
  if (saved.length === 2) {
    var sx = parseFloat(saved[0]), sy = parseFloat(saved[1]);
    for (var v = 0; v < screens.count; v++) {
      var sfr = screens.objectAtIndex(v).frame;
      if (!isNaN(sx) && !isNaN(sy) &&
          sx >= sfr.origin.x - winW && sx <= sfr.origin.x + sfr.size.width &&
          sy >= sfr.origin.y - 40 && sy <= sfr.origin.y + sfr.size.height) {
        homeX = sx; homeY = sy; break;
      }
    }
  }

  var win = $.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer(
    $.NSMakeRect(homeX, homeY, winW, winH),
    $.NSWindowStyleMaskBorderless, $.NSBackingStoreBuffered, false
  );
  win.setBackgroundColor($.NSColor.clearColor);
  win.setOpaque(false);
  win.setHasShadow(false);
  win.setLevel($.NSStatusWindowLevel);
  win.setCollectionBehavior($.NSWindowCollectionBehaviorCanJoinAllSpaces | $.NSWindowCollectionBehaviorStationary);
  win.setIgnoresMouseEvents(true);
  win.contentView.wantsLayer = true;

  var imageView = $.NSImageView.alloc.initWithFrame($.NSMakeRect(12, 48, winW - 24, 190));
  imageView.setImageScaling(3); // proportionally up or down
  imageView.setAnimates(true);
  imageView.setWantsLayer(true);
  imageView.layer.setMagnificationFilter($('nearest'));
  win.contentView.addSubview(imageView);

  function makeLabel(yPos, fontSize, bold, r, g, b, a) {
    var font = $.NSFont.fontWithNameSize(bold ? 'Menlo-Bold' : 'Menlo-Regular', fontSize);
    if (!font || font.isNil()) font = $.NSFont.systemFontOfSize(fontSize);
    var label = $.NSTextField.alloc.initWithFrame($.NSMakeRect(4, yPos, winW - 8, 18));
    label.setBezeled(false); label.setDrawsBackground(false);
    label.setEditable(false); label.setSelectable(false);
    label.setAlignment(2);
    label.setFont(font);
    label.setTextColor($.NSColor.colorWithSRGBRedGreenBlueAlpha(r, g, b, a));
    var shadow = $.NSShadow.alloc.init;
    shadow.setShadowColor($.NSColor.colorWithSRGBRedGreenBlueAlpha(0, 0, 0, 0.85));
    shadow.setShadowBlurRadius(3);
    shadow.setShadowOffset($.NSMakeSize(0, -1));
    label.setShadow(shadow);
    return label;
  }

  function cg(r, g, b, a) { return $.NSColor.colorWithSRGBRedGreenBlueAlpha(r, g, b, a).CGColor; }

  // Dark translucent pill behind the caption block so the light text stays
  // readable over any background (the pet floats over white apps too).
  var pill = $.CAShapeLayer.layer;
  pill.setPath($.CGPathCreateWithRoundedRect($.CGRectMake(16, 2, winW - 32, 48), 12, 12, null));
  pill.setFillColor(cg(0.07, 0.08, 0.12, 0.62));
  win.contentView.layer.addSublayer(pill);

  // speech-bubble tail pointing up at the pet
  var tail = $.CAShapeLayer.layer;
  var tp = $.CGPathCreateMutable();
  $.CGPathMoveToPoint(tp, null, winW / 2 - 8, 50);
  $.CGPathAddLineToPoint(tp, null, winW / 2 + 8, 50);
  $.CGPathAddLineToPoint(tp, null, winW / 2, 60);
  $.CGPathCloseSubpath(tp);
  tail.setPath(tp);
  tail.setFillColor(cg(0.07, 0.08, 0.12, 0.62));
  win.contentView.layer.addSublayer(tail);

  var nameLabel = makeLabel(30, 12, true, 0.95, 0.78, 0.45, 0.95);
  var moodLabel = makeLabel(4, 10, false, 0.86, 0.89, 1.0, 0.95);
  win.contentView.addSubview(nameLabel);
  win.contentView.addSubview(moodLabel);

  // setAlignment proved unreliable here — center deterministically by
  // sizing the label to its text and placing the frame at the midpoint.
  function centerLabel(label) {
    label.sizeToFit;
    var f = label.frame;
    label.setFrameOrigin($.NSMakePoint((winW - f.size.width) / 2, f.origin.y));
  }

  // EXP bar: progress to next evolution
  var EXPW = 110, EXPH = 4, expX = (winW - EXPW) / 2, expY = 26;
  var expTrack = $.CAShapeLayer.layer;
  expTrack.setPath($.CGPathCreateWithRoundedRect($.CGRectMake(expX, expY, EXPW, EXPH), 2, 2, null));
  expTrack.setFillColor(cg(0.50, 0.53, 0.68, 0.95)); // light enough to read on the dark pill
  win.contentView.layer.addSublayer(expTrack);
  var expFill = $.CAShapeLayer.layer;
  expFill.setFillColor(cg(0.49, 0.81, 1.0, 0.95));
  win.contentView.layer.addSublayer(expFill);
  function setExp(p) {
    var frac = Math.max(0.02, Math.min(1, (p.exp_pct || 0) / 100));
    expFill.setFillColor(p.exp_gold ? cg(1.0, 0.82, 0.25, 0.95) : cg(0.49, 0.81, 1.0, 0.95));
    expFill.setPath($.CGPathCreateWithRoundedRect(
      $.CGRectMake(expX, expY, EXPW * frac, EXPH), 2, 2, null));
  }

  // HP bar: session health (dips on tool errors, refills on completed tasks)
  var hpTrack = $.CAShapeLayer.layer;
  hpTrack.setPath($.CGPathCreateWithRoundedRect($.CGRectMake(expX, 21, EXPW, 3), 1.5, 1.5, null));
  hpTrack.setFillColor(cg(0.50, 0.53, 0.68, 0.95));
  win.contentView.layer.addSublayer(hpTrack);
  var hpFill = $.CAShapeLayer.layer;
  win.contentView.layer.addSublayer(hpFill);
  function setHp(p) {
    var frac = Math.max(0.02, Math.min(1, (p.hp_pct || 100) / 100));
    var c = p.hp_pct > 60 ? cg(0.35, 0.85, 0.45, 0.95)
          : p.hp_pct > 30 ? cg(0.95, 0.80, 0.30, 0.95) : cg(0.95, 0.35, 0.30, 0.95);
    hpFill.setFillColor(c);
    hpFill.setPath($.CGPathCreateWithRoundedRect(
      $.CGRectMake(expX, 21, EXPW * frac, 3), 1.5, 1.5, null));
  }

  // Battle FX: type-colored particle bursts + done-flash shake. Guarded —
  // any failure here must never break the pet itself.
  var TYPE_RGB = { fire: [1, .5, .2], water: [.3, .6, 1], grass: [.4, .9, .4],
    electric: [1, .9, .3], psychic: [1, .4, .8], normal: [.9, .9, .8],
    fighting: [.8, .4, .3], rock: [.7, .6, .4], ground: [.8, .7, .4],
    poison: [.7, .4, .9], bug: [.7, .9, .3], flying: [.7, .8, 1],
    ghost: [.5, .4, .9], ice: [.6, .9, 1], dragon: [.5, .5, 1],
    vpet: [.75, .95, .6] };
  var emitter = null, fxColor = '', fxOn = false, fxOffUntil = 0, shakeUntil = 0;
  function setupEmitter(type) {
    try {
      var rgb = TYPE_RGB[type] || TYPE_RGB.normal;
      if (emitter) { emitter.removeFromSuperlayer; emitter = null; }
      var img = $.NSImage.alloc.initWithSize($.NSMakeSize(8, 8));
      img.lockFocus;
      $.NSColor.colorWithSRGBRedGreenBlueAlpha(rgb[0], rgb[1], rgb[2], 1).set;
      $.NSBezierPath.bezierPathWithOvalInRect($.NSMakeRect(0, 0, 8, 8)).fill;
      img.unlockFocus;
      var cell = $.CAEmitterCell.emitterCell;
      // NSImage bridges into layer contents on macOS; a raw CGImageRef does
      // NOT survive the JXA bridge (lands as NSNull and throws)
      cell.setContents(img);
      cell.setBirthRate(1); cell.setLifetime(0.6);
      cell.setVelocity(90); cell.setVelocityRange(50);
      cell.setEmissionRange(Math.PI * 2);
      cell.setScale(0.7); cell.setScaleRange(0.3); cell.setAlphaSpeed(-1.8);
      emitter = $.CAEmitterLayer.layer;
      emitter.setEmitterPosition($.CGPointMake(winW / 2, 140));
      emitter.setBirthRate(0);
      emitter.setEmitterCells($.NSArray.arrayWithObject(cell));
      win.contentView.layer.addSublayer(emitter);
      fxColor = type;
    } catch (e) { emitter = null; fxColor = type; }
  }
  function burst(rate, ms) {
    try {
      if (emitter) { emitter.setBirthRate(rate); fxOn = true; fxOffUntil = Date.now() + ms; }
    } catch (e) {}
  }

  // ── State refresh (1s) ──
  var current = { key: '', state: 'idle', age: 9999, mon: '', shiny: false };
  var facing = 'l';
  function setSprite(mon, dir, shiny) {
    var key = mon + '|' + dir + '|' + (shiny ? 's' : '');
    if (key === current.key) return;
    var img = $.NSImage.alloc.initWithContentsOfFile(
      $(SPRITES + '/' + mon + (shiny ? '-shiny' : '') + (dir === 'r' ? '-flip' : '') + '.gif'));
    if (img && !img.isNil()) { imageView.setImage(img); current.key = key; }
  }
  function roJosa(w) {  // (으)로 by final consonant; ㄹ counts as none
    var c = w.charCodeAt(w.length - 1);
    var fin = (c - 0xAC00) % 28;
    return w + ((c >= 0xAC00 && c <= 0xD7A3 && fin > 0 && fin !== 8) ? '으로' : '로');
  }
  var evolveStart = 0, evolveOld = '', evolveNew = '', prevStage = 0, prevName = '';
  var prevRState = '', lastSlot = 0;
  function refresh() {
    var p = petState();
    if (!p) return;                        // core hasn't resolved yet
    current.state = p.state;
    current.age = p.age;
    current.mon = p.species;
    current.shiny = !!p.shiny;
    if (prevStage && p.stage > prevStage) {
      evolveStart = Date.now();
      evolveOld = prevName;
      evolveNew = p.name;
      burst(120, 600);
    }
    prevStage = p.stage;
    prevName = p.name;
    if (p.type !== fxColor) setupEmitter(p.type);
    var slot = Math.floor(Date.now() / 7000);
    if (p.state === 'working' && slot !== lastSlot) { lastSlot = slot; burst(50, 250); }
    if (p.state === 'done' && prevRState !== 'done') {
      burst(120, 350);
      shakeUntil = Date.now() + 500;
    }
    prevRState = p.state;
    setSprite(p.species, p.state === 'working' ? facing : 'l', current.shiny);
    nameLabel.setStringValue($(p.name + '  Lv.' + p.tasks +
      (p.streak >= 2 ? '  🔥' + p.streak : '')));
    var caption, evoAge = Date.now() - evolveStart;
    if (evolveStart && evoAge < 10000) {
      if (evoAge < 2500) {
        caption = p.lang === 'ko' ? '어라…!? ' + evolveOld + '의 모습이…!'
                                  : 'What? ' + evolveOld + ' is evolving!';
      } else {
        caption = p.lang === 'ko'
          ? '축하합니다! ' + josa(evolveOld, '은', '는') + ' ' + roJosa(evolveNew) + ' 진화했다!'
          : 'Congratulations! Your ' + evolveOld + ' evolved into ' + evolveNew + '!';
      }
    } else {
      caption = moodText(p);
    }
    moodLabel.setStringValue($(caption));
    centerLabel(nameLabel);
    centerLabel(moodLabel);
    setExp(p);
    setHp(p);
    win.setAlphaValue(p.state === 'idle' ? 0.55 : 1.0);
  }

  // ── Motion engine (20fps) + manual ⌥-drag ──
  var t = 0, DT = 0.05, lastDx = 0, blinkHidden = false;
  var OPT = 0x80000;
  var dragging = false, grabX = 0, grabY = 0;
  function endDrag() {
    dragging = false;
    homeX = win.frame.origin.x;
    homeY = win.frame.origin.y;
    writeFile(POSF, homeX + ' ' + homeY);
    t = Math.PI / 1.1; // roam phase where dx≈0, so no jump on release
  }
  function move() {
    // ⌥ over the pet: swallow clicks and follow the mouse while pressed.
    var optHeld = ($.CGEventSourceFlagsState(0) & OPT) !== 0;
    var loc = $.NSEvent.mouseLocation;
    var fr = win.frame;
    var inside = loc.x >= fr.origin.x && loc.x <= fr.origin.x + fr.size.width &&
                 loc.y >= fr.origin.y && loc.y <= fr.origin.y + fr.size.height;
    if (optHeld && (inside || dragging)) {
      win.setIgnoresMouseEvents(false);
      if (($.NSEvent.pressedMouseButtons & 1) !== 0) {
        if (!dragging) { dragging = true; grabX = loc.x - fr.origin.x; grabY = loc.y - fr.origin.y; }
        win.setFrameOrigin($.NSMakePoint(loc.x - grabX, loc.y - grabY));
      } else if (dragging) {
        endDrag();
      }
      return;
    }
    win.setIgnoresMouseEvents(true);
    if (dragging) endDrag();

    // evolution blink (20 fps granularity; refresh only runs at 1 Hz)
    var evoAge = Date.now() - evolveStart;
    if (evolveStart && evoAge < 2500) {
      imageView.setHidden(Math.floor(evoAge / 250) % 2 === 1);
    } else if (blinkHidden) {
      imageView.setHidden(false);
      blinkHidden = false;
    }
    if (evolveStart && evoAge < 2500) blinkHidden = true;
    // particle bursts are short pulses; shut the emitter off after each
    if (fxOn && Date.now() > fxOffUntil) {
      try { if (emitter) emitter.setBirthRate(0); } catch (e) {}
      fxOn = false;
    }

    t += DT;
    var dx = 0, dy = 0;
    switch (current.state) {
      case 'working':
        dx = -ROAM / 2 + (ROAM / 2) * Math.sin(t * 0.55);
        dy = Math.abs(Math.sin(t * 4.0)) * 4;
        var dir = dx >= lastDx ? 'r' : 'l';
        if (dir !== facing) { facing = dir; setSprite(current.mon, facing, current.shiny); }
        lastDx = dx;
        break;
      case 'thinking':
        dy = 5 + 5 * Math.sin(t * 1.6);
        break;
      case 'waiting':
        dx = 4 * Math.sin(t * 7.0);
        break;
      case 'done':
      case 'hello':
        dy = Math.abs(Math.sin(t * 5.0)) * Math.max(0, 22 - current.age * 4);
        break;
      default:
        dy = 1.5 * Math.sin(t * 0.7);
    }
    if (Date.now() < shakeUntil) {   // impact shake on task completion
      dx += Math.random() * 6 - 3;
      dy += Math.random() * 6 - 3;
    }
    win.setFrameOrigin($.NSMakePoint(homeX + dx, homeY + dy));
  }

  ObjC.registerSubclass({
    name: 'PetTicker', superclass: 'NSObject',
    methods: {
      'tick:': { types: ['void', ['id']], implementation: function() { refresh(); } },
      'move:': { types: ['void', ['id']], implementation: function() { move(); } }
    }
  });
  var ticker = $.PetTicker.alloc.init;
  $.NSTimer.scheduledTimerWithTimeIntervalTargetSelectorUserInfoRepeats(1.0, ticker, 'tick:', null, true);
  $.NSTimer.scheduledTimerWithTimeIntervalTargetSelectorUserInfoRepeats(DT, ticker, 'move:', null, true);

  refresh();
  win.orderFrontRegardless;
  $.NSApp.run;
}
